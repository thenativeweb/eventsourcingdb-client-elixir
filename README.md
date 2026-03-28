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
    {:eventsourcingdb, "~> 0.7.1"}
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

If you want to verify the API token, call `verify_api_token`. If the token is invalid, the function will return an error:

```elixir
:ok = EventSourcingDB.verify_api_token(client)
```

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

## Reading Events

To read all events of a subject, call the `read_events` function with the subject and an options struct.

The function returns a stream from which you can retrieve one event at a time:

```elixir
case EventSourcingDB.read_events(client, "/books/42") do
  {:ok, events} -> Enum.to_list(events)
  {:error, reason} -> # ...
end
```

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

## Observing Events

To observe all events of a subject, call the `observe_events` function with the subject.

The function returns a stream from which you can retrieve one event at a time:

```elixir
case EventSourcingDB.observe_events(client, "/books/42") do
  {:ok, events} -> Enum.to_list(events)
  {:error, reason} -> # ...
end
```

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

## Reading Subjects

To list all subjects, call the `read_subjects` function with `/` as the base subject. The function returns a stream from which you can retrieve one subject at a time:

```elixir
case EventSourcingDB.read_subjects(client, "/") do
  {:ok, subjects} -> Enum.to_list(subjects)
  {:error, reason} -> # ...
end
```

If you only want to list subjects within a specific branch, provide the desired base subject instead:

```elixir
EventSourcingDB.read_subjects(client, "/books")
```

## Reading Event Types

To list all event types, call the `read_event_types` function. The function returns a stream from which you can retrieve one event type at a time:

```elixir
case EventSourcingDB.read_event_types(client) do
  {:ok, event_types} -> Enum.to_list(event_types)
  {:error, reason} -> # ...
end
```

## Reading a Specific Event Type

To read a specific event type, call the `read_event_type` function with the event type as an argument. The function returns the detailed event type, which includes the schema:

```elixir
case EventSourcingDB.read_event_type(client, "io.eventsourcingdb.library.book-acquired") do
  {:ok, event_type} -> # ...
  {:error, reason} -> # ...
end
```

## Verifying an Event's Hash

To verify the integrity of an event, call the `Event.verify_hash` function on the event. This recomputes the event's hash locally and compares it to the hash stored in the event. If the hashes differ, the function returns an error:

```elixir
alias EventSourcingDB.Event

case Event.verify_hash(event) do
  :ok -> # hash is valid
  {:error, reason} -> # ...
end
```

*Note that this only verifies the hash. If you also want to verify the signature, you can skip this step and call `verify_signature` directly, which performs a hash verification internally.*

## Verifying an Event's Signature

To verify the authenticity of an event, call the `Event.verify_signature` function on the event. This requires the public key that matches the private key used for signing on the server.

The function first verifies the event's hash, and then checks the signature. If any verification step fails, it returns an error:

```elixir
alias EventSourcingDB.Event

verification_key = # public key as Ed25519 binary

case Event.verify_signature(event, verification_key) do
  :ok -> # signature is valid
  {:error, reason} -> # ...
end
```

## Using Testcontainers

Follow the instructions to [setup test containers for elixir](https://github.com/testcontainers/testcontainers-elixir).

Then you are ready to use the provided `TestContainer` in your tests:

```elixir
defmodule YourTest do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "ping", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert EventSourcingDB.ping(client) == :ok
  end
end
```

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

You can retrieve the public key (for verifying signatures) once the container has been started:

```elixir
verification_key = TestContainer.get_verification_key(esdb)
```

The `verification_key` can be passed to `Event.verify_signature` when verifying events read from the database.

### Configuring the Client Manually

In case you need to set up the client yourself, use the following functions to get details on the container:

- `TestContainer.get_base_url(esdb)` returns the full URL of the container
- `TestContainer.get_mapped_port(esdb)` returns the mapped port
- `TestContainer.get_api_token(esdb)` returns the API token
