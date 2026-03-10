# EventSourcingDB

The official Elixir client SDK for [EventSourcingDB](https://www.EventSourcingDB.io) – a purpose-built database for event sourcing.

EventSourcingDB enables you to build and operate event-driven applications with
native support for writing, reading, and observing events. This client SDK
provides convenient access to its capabilities in Elixir (read the [Elixir SDK documentation](https://hexdocs.pm/EventSourcingDB)).

For more information on EventSourcingDB, see its [official documentation](https://docs.EventSourcingDB.io/).

This client SDK includes support for [Testcontainers](https://testcontainers.com/) to spin up EventSourcingDB instances in integration tests. For details, see [Using Testcontainers](#using-testcontainers).

## Getting Started

The package can be installed by adding `EventSourcingDB` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:EventSourcingDB, "~> 0.1.0"}
  ]
end
```

Start with a `Client` that holds the connection parameters to your
EventSourcingDB instance:

```elixir
base_url = "localhost:3000"
api_token = "secret"
client = EventSourcingDB.Client.new(base_url, api_token)
```

Now every request will take the client as its first param.

## Writing Events

Call the `write_events` function and hand over a list with one or more events. You do not have to provide all event fields – some are automatically added by the server.

Specify `source`, `subject`, `type`, and `data` according to the
[CloudEvents](https://docs.EventSourcingDB.io/fundamentals/cloud-events/)
format.

The function returns the written events, including the fields added by the
server:

```elixir
event = %EventSourcingDB.EventCandidate{
  source: "https://library.EventSourcingDB.io",
  subject: "/books/42",
  type: "io.EventSourcingDB.library.book-acquired",
  data: %{
    "title" => "2001 - A Space Odyssey",
    "author" => "Arthur C. Clarke",
    "isbn" => "978-0756906788",
  }
}

written = EventSourcingDB.write_events(client, [event])

case written do
  {:ok, events} -> # ...
  {:error, type, reason} -> # ..
end
```

### Using the `IsSubjectPristine` precondition

If you only want to write events in case a subject (such as `/books/42`) does not yet have any events, use the `IsSubjectPristine` precondition to create a precondition and pass it in a vector as the second argument:

```elixir
written = EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectPristine{subject: "/books/42"}]
)

case written do
  {:ok, events} -> # ...
  {:error, type, reason} -> # ..
end
```

### Using the `IsSubjectPopulated` precondition

If you only want to write events in case a subject (such as `/books/42`) already has at least one event, use the `IsSubjectPopulated` precondition to create a precondition and pass it in a vector as the second argument:

```elixir
written = EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectPopulated{subject: "/books/42"}]
)

case written do
  {:ok, events} -> # ...
  {:error, type, reason} -> # ..
end
```

### Using the `IsSubjectOnEventId` precondition

If you only want to write events in case the last event of a subject (such as `/books/42`) has a specific ID (e.g., `0`), use the `IsSubjectOnEventId` precondition to create a precondition and pass it in a vector as the second argument:

```elixir
written = EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsSubjectOnEventId{subject: "/books/42", event_id: "0"}]
)

case written do
  {:ok, events} -> # ...
  {:error, type, reason} -> # ..
end
```

*Note that according to the CloudEvents standard, event IDs must be of type string.*

### Using the `IsEventQLQueryTrue` precondition

If you want to write events depending on an EventQL query, use the `IsEventQLQueryTrue` precondition to create a precondition and pass it in a vector as the second argument:

```elixir
written = EventSourcingDB.write_events(
  client,
  [event],
  [%EventSourcingDB.IsEventQLQueryTrue{
    query: "FROM e IN events WHERE e.type == 'io.EventSourcingDB.library.book-borrowed' PROJECT INTO COUNT () < 10"
   }]
)

case written do
  {:ok, events} -> # ...
  {:error, type, reason} -> # ..
end
```

## Reading Events

To read all events of a subject, call the `read_events` function with the
subject and an options object.

The function returns a stream from which you can retrieve one event at a time:

```elixir
result = EventSourcingDB.read_events(client, "/books/42")

case result do
  {:ok, events} -> Enum.to_list(events)
  {:error, type, reason} -> # handle error here
end
```

### Reading From Subjects Recursively

If you want to read not only all the events of a subject, but also the events of all nested subjects, set the `recursive` option to `true`:

```elixir
result = EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{recursive: true}
)
```

### Reading in Anti-Chronological Order

By default, events are read in chronological order. To read in anti-chronological order, provide the `order` option and set it using the `:antichronological` ordering:

```elixir
result = EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{
    recursive: false,
    order: :antichronological
  }
)
```

*Note that you can also use the `Chronological` ordering to explicitly enforce the default order.*

### Specifying Bounds

Sometimes you do not want to read all events, but only a range of events. For that, you can specify the `lower_bound` and `upper_bound` options – either one of them or even both at the same time.

Specify the ID and whether to include or exclude it, for both the lower and upper bound:

```elixir
result = EventSourcingDB.read_events(
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
result = EventSourcingDB.read_events(
  client,
  "/books/42",
  %EventSourcingDB.ReadEventsOptions{
    recursive: false,
    from_latest_event: %EventSourcingDB.FromLatestEventOptions{
      subject: "/books/42",
      type: "io.EventSourcingDB.library.book-borrowed"
      if_event_is_missing: :read_everything
    }
  }
)
```

*Note that `from_latest_event` and `lower_bound` can not be provided at the sametime.*

## Running EventQL Queries

To run an EventQL query, call the `run_eventql_query` function and provide the query as argument. The function returns a stream.

```elixir
result = EventSourcingDB.run_eventql_query(client, "FROM e IN events PROJECT INTO e")

case result do
  {:ok, events} -> Enum.to_list(events)
  {:error, type, reason} -> # handle error here
end
```

## Observing Events

To observe all events of a subject, call the `observe_events` function with the subject.

The function returns a stream from which you can retrieve one event at a time:

```elixir
result = EventSourcingDB.observe_events(client, "/books/42")

case result do
  {:ok, events} -> Enum.to_list(events)
  {:error, type, reason} -> # handle error here
end
```

### Observing From Subjects Recursively

If you want to observe not only all the events of a subject, but also the events of all nested subjects, set the `recursive` option to `true`:

```elixir
result = EventSourcingDB.observe_events(
  client,
  "/books/42",
  %EventSourcingDB.ObserveEventsOptions{
    recursive: true
  }
)
```

This also allows you to observe *all* events ever written. To do so, provide `/`
as the subject and set `recursive` to `true`, since all subjects are nested
under the root subject.

### Specifying Bounds

Sometimes you do not want to observe all events, but only a range of events. For that, you can specify the `lower_bound` option.

Specify the ID and whether to include or exclude it:

```elixir
result = EventSourcingDB.observe_events(
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
result = EventSourcingDB.observe_events(
  client,
  "/books/42",
  %EventSourcingDB.ObserveEventsOptions{
    recursive: false,
    from_latest_event: %EventSourcingDB.FromLatestEventOptions{
      subject: "/books/42",
      type: "io.EventSourcingDB.library.book-borrowed",
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
  "io.EventSourcingDB.library.book-acquired",
  %{
    "type" => "object",
    "properties" => %{
      "title" =>  %{ "type": "string" },
      "author" => %{ "type": "string" },
      "isbn" =>   %{ "type": "string" },
    },
    "required" => [
      "title",
      "author",
      "isbn",
    ],
    "additionalProperties" => false,
  }),
)
```

## Reading Subjects

To list all subjects, call the `list_subjects` function with `/` as the base subject. The function returns a stream from which you can retrieve one subject at a time:

```elixir
result = EventSourcingDB.read_subjects(client, "/")

case result do
  {:ok, subjects} -> Enum.to_list(subjects)
  {:error, type, reason} -> # handle error here
end
```

If you only want to list subjects within a specific branch, provide the desired base subject instead:

```elixir
result = EventSourcingDB.read_subjects(client, "/books")
```

## Reading a Specific Event Type

To list a specific event type, call the `read_event_type` function. The function returns the detailed event type, which includes the schema:

```elixir
result = EventSourcingDB.read_event_types(client, "io.EventSourcingDB.library.book-acquired")

case result do
  {:ok, event_types} -> Enum.to_list(event_types)
  {:error, error_type, reason} -> # ...
end
```

## Verifying an Event's Hash

TODO

## Verifying an Event's Signature

TODO

## Using Testcontainers

Follow the instructions to [setup test containers for elixir](https://github.com/testcontainers/testcontainers-elixir).

Then you are ready to use the provideded `TestContainer` in your tests:

```elixir
defmodule YourTest do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new(())

  test "ping", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    # do sth with client

    assert EventSourcingDB.ping(client) == :ok
  end
end
```

### Configuring the Container Instance

By default, `TestContainer` uses the `latest` tag of the official EventSourcingDB Docker image. To change that use the provided builder and call the `with_image_tag` function.

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
