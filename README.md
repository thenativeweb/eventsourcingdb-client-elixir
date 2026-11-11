# EventSourcingDB

The official Elixir client SDK for [EventSourcingDB](https://www.eventfoundation.io/products/eventsourcingdb) – a purpose-built database for event sourcing.

The complete documentation of this client SDK, including preconditions, EventQL, observing events, handling errors, Testcontainers, and upgrading, is available at **[https://www.eventfoundation.io/docs/eventsourcingdb/sdks/elixir](https://www.eventfoundation.io/docs/eventsourcingdb/sdks/elixir)**.

## Getting Started

The package can be installed by adding `eventsourcingdb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:eventsourcingdb, "~> 2.5.1"}
  ]
end
```

Create a client with the URL of your EventSourcingDB instance and the API token to use, and check whether the instance is reachable:

```elixir
client = EventSourcingDB.Client.new("http://localhost:3000", "secret")

:ok = EventSourcingDB.ping(client)
```

Write an event:

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

Read the events of a subject:

```elixir
case EventSourcingDB.read_events(client, "/books/42") do
  {:ok, events} -> Enum.to_list(events)
  {:error, reason} -> # ...
end
```

For everything else, see the **[complete documentation](https://www.eventfoundation.io/docs/eventsourcingdb/sdks/elixir)**.
