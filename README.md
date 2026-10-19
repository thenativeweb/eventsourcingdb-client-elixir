# EventSourcingDB

The official Elixir client SDK for [EventSourcingDB](https://www.eventsourcingdb.io) – a purpose-built database for event sourcing.

EventSourcingDB enables you to build and operate event-driven applications with native support for writing, reading, and observing events. This client SDK provides convenient access to its capabilities in Elixir.

For more information on EventSourcingDB, see its [official documentation](https://docs.eventsourcingdb.io/).

This client SDK includes support for [Testcontainers](https://testcontainers.com/) to spin up EventSourcingDB instances in integration tests. For details, see [Using Testcontainers](#using-testcontainers).

## Getting Started

The package can be installed by adding `eventsourcingdb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:eventsourcingdb, "~> 2.1.0"}
  ]
end
```

Create a client by providing the URL of your EventSourcingDB instance and the API token to use:

```elixir
client = EventSourcingDB.Client.new("http://localhost:3000", "secret")
```

Then call the `ping` function to check whether the instance is reachable. If it is not, the function will return an error:

```elixir
:ok = EventSourcingDB.ping(client)
```

*Note that `ping` does not require authentication, so the call may succeed even if the API token is invalid.*

If you want to verify the API token, call `verify_api_token`. If the token is invalid, the function will return an `EventSourcingDB.Errors.DbApiError` with the status `401`:

```elixir
:ok = EventSourcingDB.verify_api_token(client)
```

### Talking to Servers With and Without the v2 API

The client SDK works with servers that offer the v2 API of EventSourcingDB, and with servers that do not, such as EventSourcingDB 1.2. Creating a client makes no request. On the first request to a server, the client SDK asks the server for `GET /api/v2/system/ping`, and remembers the answer for every client of the same `base_url`: it then talks to the server through the v2 API if the server offers it, and through the v1 API otherwise. If that first request can not find out, for example because the server is not reachable, the request fails with that error, and the next one asks again. Requests that start at the same time share a single attempt to find out.

Over the v2 API, every read uses the HTTP method `QUERY` ([RFC 10008](https://www.rfc-editor.org/rfc/rfc10008)), so a proxy in front of EventSourcingDB has to let `QUERY` requests through. There is no fallback to `POST`.

The client SDK remembers the answers, and keeps track of the attempts to find out, in processes of its own application, `:eventsourcingdb`, which starts as a dependency of yours.

### Using HTTP/2

By default, the client uses HTTP/1.1. To use HTTP/2, which EventSourcingDB offers over HTTPS, pass the protocol on to [Req](https://hexdocs.pm/req) via the `req_options` of the client:

```elixir
client = EventSourcingDB.Client.new(
  base_url: "https://localhost:4000",
  api_token: "secret",
  req_options: [connect_options: [protocols: [:http2]]]
)
```

Streams work over HTTP/2 as well, and stay open for as long as data arrives.

### Configuring the Stall Timeout

A request fails once it waits for the server for 30 seconds without anything arriving: while connecting, while waiting for the response headers, or while waiting for the rest of the response. Everything that arrives restarts the 30 seconds, so this does not limit how long a request takes: a stream stays open for as long as events, rows, or heartbeats keep arriving. To wait for a different time, pass the `stall_timeout` option to the client, in milliseconds:

```elixir
client = EventSourcingDB.Client.new(
  base_url: "http://localhost:3000",
  api_token: "secret",
  stall_timeout: 10_000
)
```

A request that stalls returns an `EventSourcingDB.Errors.ConnectionStalled` error, and a stream that stalls while you enumerate it raises that error. Writing events and registering an event schema return it wrapped in an `EventSourcingDB.Errors.OutcomeUnknown` once the request was sent (see [Handling Errors](#handling-errors)).

Req retries a request that is safe to repeat after a transient error, such as a timeout over HTTP/1, by default three times, after about one, two, and four seconds. Among the requests of this client SDK, that is only `ping`, since it uses GET, together with the request with which a client asks for the API of the server before its first `ping`. So with the default stall timeout, a `ping` to a server that stalls fails only after about two minutes: four attempts of 30 seconds each, plus the seven seconds in between. To have it fail after the stall timeout, turn off Req's retries via `req_options: [retry: false]`. A request that the server refuses for its rate limit, with the status `429`, is never retried.

If you do not set `stall_timeout`, but pass a `receive_timeout` on to Req via `req_options`, every request whose answer carries no heartbeats waits for that `receive_timeout` instead, as it always has, and connecting keeps Req's own timeout. A `stall_timeout` that you set takes precedence. Over the v2 API, every stream carries heartbeats, writes included, while over the v1 API, only observing events and running EventQL queries do.

*Note that over HTTP/2, a request with a single answer must be answered completely within the stall timeout, since there [Finch](https://hexdocs.pm/finch) bounds the request as a whole rather than each wait for data. Over the v2 API, these are `ping`, `verify_api_token`, and `read_event_type`, and over the v1 API, writing events and registering an event schema as well. Streams are not affected.*

## Writing Events

Call the `write_events` function and hand over a list with one or more events. You do not have to provide all event fields – some are automatically added by the server.

Specify `source`, `subject`, `type`, and `data` according to the [CloudEvents](https://docs.eventsourcingdb.io/fundamentals/cloud-events/) format.

The function returns the written events, including the fields added by the server:

```elixir
event = %EventSourcingDB.EventCandidate{
  source: "https://library.eventsourcingdb.io",
  subject: "/books/42",
  type: "io.eventsourcingdb.library.book-acquired",
  data: %{
    "title" => "2001 – A Space Odyssey",
    "author" => "Arthur C. Clarke",
    "isbn" => "978-0756906788"
  }
}

case EventSourcingDB.write_events(client, [event]) do
  {:ok, events} -> # ...
  {:error, reason} -> # ...
end
```

### Using the `IsSubjectPristine` precondition

If you only want to write events in case a subject (such as `/books/42`) does not yet have any events, use the `IsSubjectPristine` precondition and pass it in a list as the third argument:

```elixir
case EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectPristine{subject: "/books/42"}]
) do
  {:ok, events} -> # ...
  {:error, reason} -> # ...
end
```

### Using the `IsSubjectPopulated` precondition

If you only want to write events in case a subject (such as `/books/42`) already has at least one event, use the `IsSubjectPopulated` precondition and pass it in a list as the third argument:

```elixir
case EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectPopulated{subject: "/books/42"}]
) do
  {:ok, events} -> # ...
  {:error, reason} -> # ...
end
```

### Using the `IsSubjectOnEventId` precondition

If you only want to write events in case the last event of a subject (such as `/books/42`) has a specific ID (e.g., `0`), use the `IsSubjectOnEventId` precondition and pass it in a list as the third argument:

```elixir
case EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectOnEventId{subject: "/books/42", event_id: "0"}]
) do
  {:ok, events} -> # ...
  {:error, reason} -> # ...
end
```

*Note that according to the CloudEvents standard, event IDs must be of type string.*

### Using the `IsEventQLQueryTrue` precondition

If you want to write events depending on an EventQL query, use the `IsEventQLQueryTrue` precondition:

```elixir
case EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsEventQLQueryTrue{
    query: "FROM e IN events WHERE e.type == 'io.eventsourcingdb.library.book-borrowed' PROJECT INTO COUNT() < 10"
  }]
) do
  {:ok, events} -> # ...
  {:error, reason} -> # ...
end
```

*Note that the query must return a single row with a single value, which is interpreted as a boolean.*

### Handling Errors

If EventSourcingDB refuses the write, the function returns an `EventSourcingDB.Errors.DbApiError`, whose `code` tells why, for example that a precondition does not hold. `EventSourcingDB.ErrorCode` holds the codes:

```elixir
case EventSourcingDB.write_events(client, [event], preconditions) do
  {:ok, events} ->
    # ...

  {:error, %EventSourcingDB.Errors.DbApiError{code: code}} ->
    if code == EventSourcingDB.ErrorCode.precondition_violated() do
      # ...
    end

  {:error, %EventSourcingDB.Errors.OutcomeUnknown{cause: cause}} ->
    # ...
end
```

#### Knowing Whether a Write Was Stored

If the write fails in a way that leaves open whether EventSourcingDB stored it, for example because the connection stalled or broke after the request was sent, or because the answer did not come from EventSourcingDB, the function returns an `EventSourcingDB.Errors.OutcomeUnknown`, which holds the error as its `cause`. EventSourcingDB never stores a write halfway, so before you repeat it, find out whether it was stored, for example by reading the events of the subject. Every other error means that the events were not stored: the connection could not be established at all, or EventSourcingDB refused the write.

## Reading Events

To read all events of a subject, call the `read_events` function with the subject and an options struct.

The function returns a stream from which you can retrieve one event at a time:

```elixir
case EventSourcingDB.read_events(client, "/books/42") do
  {:ok, events} -> Enum.to_list(events)
  {:error, reason} -> # ...
end
```

If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the [stall timeout](#configuring-the-stall-timeout), an `EventSourcingDB.Errors.TransmissionError` if the connection fails or the stream ends before EventSourcingDB finished it, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

Servers with the v2 API report an error about the request itself, such as a malformed subject, within the stream as well, so the stream raises it once you enumerate it, while servers without the v2 API answer with the error right away.

Like all functions that return a stream, `read_events` receives the response as messages sent to the calling process, so enumerate the stream in that process. While you do, the stream leaves the other messages of the process, such as the calls and casts of a GenServer, in its mailbox.

### Reading From Subjects Recursively

If you want to read not only all the events of a subject, but also the events of all nested subjects, set the `recursive` option to `true`:

```elixir
EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{recursive: true}
)
```

This also allows you to read *all* events ever written. To do so, provide `/` as the subject and set `recursive` to `true`, since all subjects are nested under the root subject.

### Reading in Anti-Chronological Order

By default, events are read in chronological order. To read in anti-chronological order, provide the `order` option and set it to `:antichronological`:

```elixir
EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{
    recursive: false,
    order: :antichronological
  }
)
```

*Note that you can also use `:chronological` to explicitly enforce the default order.*

### Specifying Bounds

Sometimes you do not want to read all events, but only a range of events. For that, you can specify the `lower_bound` and `upper_bound` options – either one of them or even both at the same time.

Specify the ID and whether to include or exclude it, for both the lower and upper bound:

```elixir
EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{
    recursive: false,
    lower_bound: %EventSourcingDB.BoundOptions{
      type: :inclusive,
      id: "100"
    },
    upper_bound: %EventSourcingDB.BoundOptions{
      type: :exclusive,
      id: "200"
    }
  }
)
```

### Starting From the Latest Event of a Given Type

To read starting from the latest event of a given type, provide the `from_latest_event` option and specify the subject, the type, and how to proceed if no such event exists.

Possible options are `:read_nothing`, which skips reading entirely, or `:read_everything`, which effectively behaves as if `from_latest_event` was not specified:

```elixir
EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{
    recursive: false,
    from_latest_event: %EventSourcingDB.ReadFromLatestEventOptions{
      subject: "/books/42",
      type: "io.eventsourcingdb.library.book-borrowed",
      if_event_is_missing: :read_everything
    }
  }
)
```

*Note that `from_latest_event` and `lower_bound` can not be provided at the same time.*

## Running EventQL Queries

To run an EventQL query, call the `run_eventql_query` function and provide the query as argument. The function returns a stream:

```elixir
case EventSourcingDB.run_eventql_query(client, "FROM e IN events PROJECT INTO e") do
  {:ok, rows} -> Enum.to_list(rows)
  {:error, reason} -> # ...
end
```

*Note that each row returned by the stream matches the projection specified in your query.*

While there are no rows to deliver, EventSourcingDB sends a heartbeat every second. If neither a row nor a heartbeat arrives for the [stall timeout](#configuring-the-stall-timeout), 30 seconds by default, the stream closes the connection and raises an `EventSourcingDB.Errors.ConnectionStalled` error.

If anything else goes wrong while you enumerate the stream, the stream closes the connection as well and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

## Observing Events

To observe all events of a subject, call the `observe_events` function with the subject.

The function returns a stream from which you can retrieve one event at a time:

```elixir
case EventSourcingDB.observe_events(client, "/books/42") do
  {:ok, events} -> Enum.to_list(events)
  {:error, reason} -> # ...
end
```

While there are no events to deliver, EventSourcingDB sends a heartbeat every second. If neither an event nor a heartbeat arrives for the [stall timeout](#configuring-the-stall-timeout), 30 seconds by default, the stream closes the connection and raises an `EventSourcingDB.Errors.ConnectionStalled` error.

Observing events never ends on its own. If the server ends the stream nonetheless without reporting an error, the stream raises an `EventSourcingDB.Errors.TransmissionError`, as when the connection fails. A server that shuts down reports that as an error first.

If anything else goes wrong while you enumerate the stream, the stream closes the connection as well and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

### Observing From Subjects Recursively

If you want to observe not only all the events of a subject, but also the events of all nested subjects, set the `recursive` option to `true`:

```elixir
EventSourcingDB.observe_events(
  client,
  "/books/42",
  %EventSourcingDB.ObserveEventsOptions{
    recursive: true
  }
)
```

This also allows you to observe *all* events ever written. To do so, provide `/` as the subject and set `recursive` to `true`, since all subjects are nested under the root subject.

### Specifying Bounds

Sometimes you do not want to observe all events, but only a range of events. For that, you can specify the `lower_bound` option.

Specify the ID and whether to include or exclude it:

```elixir
EventSourcingDB.observe_events(
  client,
  "/books/42",
  %EventSourcingDB.ObserveEventsOptions{
    recursive: false,
    lower_bound: %EventSourcingDB.BoundOptions{
      type: :inclusive,
      id: "100"
    }
  }
)
```

### Starting From the Latest Event of a Given Type

To observe starting from the latest event of a given type, provide the `from_latest_event` option and specify the subject, the type, and how to proceed if no such event exists.

Possible options are `:wait_for_event`, which waits for an event of the given type to happen, or `:read_everything`, which effectively behaves as if `from_latest_event` was not specified:

```elixir
EventSourcingDB.observe_events(
  client,
  "/books/42",
  %EventSourcingDB.ObserveEventsOptions{
    recursive: false,
    from_latest_event: %EventSourcingDB.ObserveFromLatestEventOptions{
      subject: "/books/42",
      type: "io.eventsourcingdb.library.book-borrowed",
      if_event_is_missing: :read_everything
    }
  }
)
```

*Note that `from_latest_event` and `lower_bound` can not be provided at the same time.*

## Registering an Event Schema

To register an event schema, call the `register_event_schema` function and hand over an event type and the desired schema:

```elixir
EventSourcingDB.register_event_schema(
  client,
  "io.eventsourcingdb.library.book-acquired",
  %{
    "type" => "object",
    "properties" => %{
      "title" => %{"type" => "string"},
      "author" => %{"type" => "string"},
      "isbn" => %{"type" => "string"}
    },
    "required" => [
      "title",
      "author",
      "isbn"
    ],
    "additionalProperties" => false
  }
)
```

The function returns the event with which EventSourcingDB confirms the registration, whose `data` holds the `type` and the `schema`. As for [writing events](#handling-errors), it returns an `EventSourcingDB.Errors.OutcomeUnknown` if it fails in a way that leaves open whether EventSourcingDB registered the schema, and an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB refuses it, for example with the code `EventSourcingDB.ErrorCode.event_schema_already_registered()` if the event type has a schema already.

## Reading Subjects

To list subjects, call the `read_subjects` function with a subject and an options struct, which must say whether to read recursively. To list all subjects, provide `/` as the subject and set `recursive` to `true`. The function returns a stream from which you can retrieve one subject at a time:

```elixir
case EventSourcingDB.read_subjects(
  client,
  "/",
  %EventSourcingDB.ReadSubjectsOptions{recursive: true}
) do
  {:ok, subjects} -> Enum.to_list(subjects)
  {:error, reason} -> # ...
end
```

If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the [stall timeout](#configuring-the-stall-timeout), an `EventSourcingDB.Errors.TransmissionError` if the connection fails or the stream ends before EventSourcingDB finished it, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

If you only want to list subjects within a specific branch, provide the desired subject instead. With `recursive` set to `false`, the stream contains the subject alone, if it exists:

```elixir
EventSourcingDB.read_subjects(
  client,
  "/books",
  %EventSourcingDB.ReadSubjectsOptions{recursive: false}
)
```

The options are required. Without a `recursive` option of `true` or `false`, the function raises an `ArgumentError`.

## Reading Event Types

To list all event types, call the `read_event_types` function. The function returns a stream from which you can retrieve one event type at a time, as an `EventSourcingDB.EventType` with the name of the type as `type`, whether events of the type were written as `has_events`, and its `schema`, if one was registered:

```elixir
case EventSourcingDB.read_event_types(client) do
  {:ok, event_types} -> Enum.to_list(event_types)
  {:error, reason} -> # ...
end
```

If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the [stall timeout](#configuring-the-stall-timeout), an `EventSourcingDB.Errors.TransmissionError` if the connection fails or the stream ends before EventSourcingDB finished it, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

## Reading a Specific Event Type

To read a specific event type, call the `read_event_type` function with the event type as an argument. The function returns the detailed event type, an `EventSourcingDB.EventType`, which includes the schema. If EventSourcingDB knows no such event type, the function returns an `EventSourcingDB.Errors.DbApiError` with the code `EventSourcingDB.ErrorCode.event_type_unknown()`:

```elixir
case EventSourcingDB.read_event_type(client, "io.eventsourcingdb.library.book-acquired") do
  {:ok, event_type} -> # ...
  {:error, reason} -> # ...
end
```

## Verifying an Event's Hash

To verify the integrity of an event, call the `Event.verify_hash` function on the event. This recomputes the event's hash locally and compares it to the hash stored in the event. If the hashes differ, the function returns an `EventSourcingDB.Errors.HashVerificationFailed` error:

```elixir
alias EventSourcingDB.Event

case Event.verify_hash(event) do
  :ok -> # hash is valid
  {:error, reason} -> # ...
end
```

The hash tells which version of the hash it is, and an event keeps the version it was written with: a hash that starts with `esdb:hash:v2:` is of version 2, which EventSourcingDB writes since version 1.3, and a hash without such a prefix is of version 1. The function verifies both. A hash whose prefix names a version that this client SDK does not know, such as `esdb:hash:v3:`, can not be verified, so the function returns an `EventSourcingDB.Errors.UnsupportedHashVersion` error, which names the version, rather than report the event as tampered with.

Both versions hash the data of the event exactly as EventSourcingDB sent it, byte for byte, which every event that the client SDK returns keeps for this purpose. For an event that you create yourself, for example with `Event.new/1`, only the decoded data is known, so the function encodes it again with Jason, which can differ from what EventSourcingDB sent, for example for `&`, `<`, and `>`, which EventSourcingDB escapes.

Events that the client SDK returns carry this text in the field `__raw_data__`, so comparing such an event with `==` against one built with `Event.new/1` or a struct literal no longer matches, while pattern matching is unaffected.

*Note that this only verifies the hash. If you also want to verify the signature, you can skip this step and call `verify_signature` directly, which performs a hash verification internally.*

## Verifying an Event's Signature

To verify the authenticity of an event, call the `Event.verify_signature` function on the event. This requires the public key that matches the private key used for signing on the server.

The function first verifies the event's hash, and then checks the signature. If any verification step fails, it returns an error, for example an `EventSourcingDB.Errors.HashVerificationFailed` error if the hash is invalid, an `EventSourcingDB.Errors.UnsupportedHashVersion` error if the hash is of a version that this client SDK does not know, or an `EventSourcingDB.Errors.SignatureVerificationFailed` error if the signature is invalid:

```elixir
alias EventSourcingDB.Event

verification_key = # public key as Ed25519 binary

case Event.verify_signature(event, verification_key) do
  :ok -> # signature is valid
  {:error, reason} -> # ...
end
```

## Understanding Errors

Every error that EventSourcingDB reports is an `EventSourcingDB.Errors.DbApiError`, whether EventSourcingDB answers with a status other than `200`, or reports the error within its answer. It carries:

- `code` – the code of the error, a URL such as `https://docs.eventsourcingdb.io/errors/precondition-violated`, exactly as EventSourcingDB sends it, or `nil` for an error without a code
- `description` – the text that describes the error
- `details` – the details of the error as a map, as the v2 API sends them, or `nil`
- `status` – the HTTP status of the answer, which is `200` for an error that EventSourcingDB reports within its answer
- `retry_after` – for the status `429`, with which EventSourcingDB refuses a request for its rate limit, the number of seconds to wait before trying again, as the `Retry-After` header says, or `nil` without the header

`EventSourcingDB.ErrorCode` holds every code that EventSourcingDB reports, one function per code, so that you do not need to compare strings. To match a code in a pattern, read it into a module attribute first:

```elixir
@precondition_violated EventSourcingDB.ErrorCode.precondition_violated()

def handle({:error, %EventSourcingDB.Errors.DbApiError{code: @precondition_violated}}) do
  # ...
end
```

Servers without the v2 API report errors without codes. For the errors that clearly match one, such as a precondition that does not hold, an unknown event type, or a store in read-only mode, the client SDK assigns the code of the v2 API itself, so that the same code works with both.

Besides, a request may fail with an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the [stall timeout](#configuring-the-stall-timeout), with an `EventSourcingDB.Errors.TransmissionError` if the connection fails, or with an `EventSourcingDB.Errors.InvalidServerHeader` if the answer does not come from EventSourcingDB. Writing events and registering an event schema return an `EventSourcingDB.Errors.OutcomeUnknown` instead whenever the write may have been stored nonetheless (see [Handling Errors](#handling-errors)).

## Using Testcontainers

Follow the instructions to [setup test containers for elixir](https://github.com/testcontainers/testcontainers-elixir).

Then you are ready to use the provided `TestContainer` in your tests:

```elixir
defmodule YourTest do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import EventSourcingDB.TestContainer.ExUnit

  @moduletag timeout: 150_000

  container(:esdb, TestContainer.new())

  test "ping", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert EventSourcingDB.ping(client) == :ok
  end
end
```

Starting the container can take up to three times the startup timeout, and that time counts toward the timeout of a test, unless the tests share the container with `shared: true`.

Alternatively, start and stop the container yourself, with the `start` and the `stop` function:

```elixir
setup do
  {:ok, esdb} = TestContainer.start(TestContainer.new())
  on_exit(fn -> TestContainer.stop(esdb) end)

  %{esdb: esdb}
end
```

The `container` macro of `Testcontainers.ExUnit` still works, but starts the container without the replacement, the cleanup, and the startup timeout of this SDK.

### Configuring the Container Instance

By default, `TestContainer` uses the `latest` tag of the official EventSourcingDB Docker image. To change that, call the `with_image_tag` function:

```elixir
container(
  :esdb,
  TestContainer.new()
  |> TestContainer.with_image_tag("1.0.0")
)
```

Similarly, you can configure the port to use and the API token. Call the `with_port` or the `with_api_token` function respectively:

```elixir
container(
  :esdb,
  TestContainer.new()
  |> TestContainer.with_port(4000)
  |> TestContainer.with_api_token("secret")
)
```

If you want to sign events, call the `with_signing_key` function. This generates a new signing and verification key pair inside the container:

```elixir
container(
  :esdb,
  TestContainer.new()
  |> TestContainer.with_signing_key()
)
```

You can retrieve the private key (for signing) and the public key (for verifying signatures) once the container has been started:

```elixir
signing_key = TestContainer.get_signing_key(esdb)
verification_key = TestContainer.get_verification_key(esdb)
```

The `signing_key` is the private key EventSourcingDB signs events with. The `verification_key` can be passed to `Event.verify_signature` when verifying events read from the database.

The `container` macro and the `start` function pull the image if it is missing, and then wait until the database in the container answers a ping, for 30 seconds at most, not counting the pull. To change this time, call the `with_startup_timeout` function with the milliseconds:

```elixir
container(
  :esdb,
  TestContainer.new()
  |> TestContainer.with_startup_timeout(60_000)
)
```

If a container keeps running, but does not become reachable in time, it is replaced with a new one, up to three containers in total. If Docker fails, or if the container exits, the start fails at once, and if the container exited, the error contains the last 20 lines of its log. The `container` macro raises the error, an `EventSourcingDB.Errors.ContainerStartFailed`, and the `start` function returns it. In any case, every container that failed to start is removed.

### Configuring the Client Manually

In case you need to set up the client yourself, use the following functions to get details on the container:

- `TestContainer.get_base_url(esdb)` returns the full URL of the container
- `TestContainer.get_mapped_port(esdb)` returns the mapped port
- `TestContainer.get_api_token(esdb)` returns the API token

## Upgrading From Version 1

Version 2 of the client SDK talks to servers with the v2 API through it (see [Talking to Servers With and Without the v2 API](#talking-to-servers-with-and-without-the-v2-api)), and follows the v2 API in its own names. These are the changes that break code written for version 1:

- **Event types name their type `type`, and tell whether they have events.** `EventSourcingDB.EventType` replaces `event_type` with `type`, and `is_phantom` with `has_events`, which is its opposite.
  - Before: `%EventSourcingDB.EventType{event_type: type, is_phantom: false}`
  - After: `%EventSourcingDB.EventType{type: type, has_events: true}`
- **Registering an event schema confirms the type as `type`.** The `data` of the event that `register_event_schema` returns names the type `type`, also for servers without the v2 API.
  - Before: `event.data["eventType"]`
  - After: `event.data["type"]`
- **Reading subjects requires an options struct that says whether to read recursively.** `read_subjects/2` and `read_subjects!/2` become `read_subjects/3` and `read_subjects!/3`, which raise an `ArgumentError` without a `recursive` option. With `recursive: false`, they list the subject alone.
  - Before: `EventSourcingDB.read_subjects(client, "/books")`
  - After: `EventSourcingDB.read_subjects(client, "/books", %EventSourcingDB.ReadSubjectsOptions{recursive: true})`
- **Every error that EventSourcingDB reports is a `DbApiError`.** It replaces `ApiError`, `DBError`, and `ApiTokenInvalid`, which are gone.
  - Before: `{:error, %EventSourcingDB.Errors.ApiError{reason: text}}`
  - After: `{:error, %EventSourcingDB.Errors.DbApiError{status: status, description: text, code: code}}`
  - Before: `%EventSourcingDB.Errors.DBError{payload: %{"error" => text}}`
  - After: `%EventSourcingDB.Errors.DbApiError{status: 200, description: text, code: code, details: details}`
  - Before: `{:error, %EventSourcingDB.Errors.ApiTokenInvalid{}}`
  - After: `{:error, %EventSourcingDB.Errors.DbApiError{status: 401}}`
- **A stall is a `ConnectionStalled`.** It replaces `HeartbeatTimeout`, which is gone, and a `TransmissionError` with the reason `:timeout`.
  - Before: `%EventSourcingDB.Errors.HeartbeatTimeout{}`, or `%EventSourcingDB.Errors.TransmissionError{reason: %{reason: :timeout}}`
  - After: `%EventSourcingDB.Errors.ConnectionStalled{}`
- **A write that may have been stored fails with `OutcomeUnknown`.** Writing events and registering an event schema wrap the error in an `OutcomeUnknown` whenever the write may have been stored nonetheless, for example after a stall, a broken connection, or a `500`.
  - Before: `{:error, %EventSourcingDB.Errors.TransmissionError{}}`
  - After: `{:error, %EventSourcingDB.Errors.OutcomeUnknown{cause: %EventSourcingDB.Errors.ConnectionStalled{}}}`
- **Observing events fails if the server ends the stream.** A stream of observed events that the server ends without reporting an error raises a `TransmissionError`, rather than end.
  - Before: `Enum.to_list(events)` returned the events
  - After: `Enum.to_list(events)` raises an `EventSourcingDB.Errors.TransmissionError`
- **A request that the rate limit refuses is not retried.** Req no longer retries a `ping` that the server answers with the status `429`; it returns a `DbApiError` with the status `429` and `retry_after`.
  - Before: Req retried the `ping` three times
  - After: `{:error, %EventSourcingDB.Errors.DbApiError{status: 429, retry_after: seconds}}`
- **`EventType.new/1` reads the fields of the v2 API.** It takes the type from `"type"` and whether the type has events from `"hasEvents"`, so a map with the fields of the v1 API, `"eventType"` and `"isPhantom"`, results in an event type whose `type` and `has_events` are `nil`.
  - Before: `EventSourcingDB.EventType.new(%{"eventType" => type, "isPhantom" => false})`
  - After: `EventSourcingDB.EventType.new(%{"type" => type, "hasEvents" => true})`
- **The client SDK starts an application of its own.** `:eventsourcingdb` now has an application module, which starts the processes that remember the API of each server and keep track of the attempts to find it out, and attaches a handler to the telemetry events of Finch, which tell whether a write that failed was sent. Mix starts it as a dependency, so this only matters for code that does not start the applications of its dependencies.
  - Before: `:eventsourcingdb` started no processes
  - After: `:eventsourcingdb` starts its supervisor, `EventSourcingDB.Supervisor`
- **The client SDK asks a server for its API on the first request to it.** The first request to a server is preceded by `GET /api/v2/system/ping`, and reads over the v2 API use the method `QUERY`, which a proxy in front of EventSourcingDB has to let through. Over the v2 API, an error about a read itself, such as a malformed subject, arrives within the stream, so it is raised once you enumerate the stream.
  - Before: `EventSourcingDB.read_events(client, "malformed")` returned `{:error, %EventSourcingDB.Errors.ApiError{}}`
  - After: over the v2 API, `{:ok, events}`, and `Enum.to_list(events)` raises an `EventSourcingDB.Errors.DbApiError` with the code `EventSourcingDB.ErrorCode.subject_malformed()`

To start the test container with the replacement, the cleanup, and the startup timeout of this SDK, switch the import of `Testcontainers.ExUnit` to `EventSourcingDB.TestContainer.ExUnit`.
