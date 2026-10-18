defmodule EventSourcingDB do
  @moduledoc """
  `EventSourcingDB` client SDK.

  The client SDK works with servers with and without the v2 API of EventSourcingDB. A client finds out which API its server offers on its first request, with a request for `/api/v2/system/ping`, and remembers the answer.

  Over the v2 API, every read uses the HTTP method `QUERY` (RFC 10008), so a proxy in front of EventSourcingDB has to let it through. There is no fallback to `POST`.
  """

  alias EventSourcingDB.{
    ObserveEventsOptions,
    ReadEventsOptions,
    ReadSubjectsOptions,
    Client,
    Event,
    EventCandidate,
    EventType,
    ManagementEvent
  }

  alias EventSourcingDB.{
    IsSubjectPristine,
    IsSubjectPopulated,
    IsSubjectOnEventId,
    IsEventQLQueryTrue
  }

  alias EventSourcingDB.Transport

  #
  # region Public API
  #

  @typedoc """
  The response format for a request
  """
  @type primitive_response() :: :ok | {:error, Exception.t()}

  @typedoc """
  The response format for a request
  """
  @type response(t) :: {:ok, t} | {:error, Exception.t()}

  @typedoc """
  The response format for a force request
  """
  @type response!(t) :: t

  @typedoc """
  The response format for a request returning a stream
  """
  @type stream_response(t) :: {:ok, Enumerable.t(t)} | {:error, Exception.t()}

  @typedoc """
  The response format for a force request returning a stream
  """
  @type stream_response!(t) :: Enumerable.t(t)

  @type precondition() ::
          IsEventQLQueryTrue.t()
          | IsSubjectOnEventId.t()
          | IsSubjectPopulated.t()
          | IsSubjectPristine.t()

  @doc """
  Pings the DB instance to check if it is reachable.

  ## Examples

      iex> client = EventSourcingDB.Client.new("http://localhost:3000", "secrettoken")
      iex> EventSourcingDB.ping(client)
      :ok
  """
  @spec ping(Client.t()) :: primitive_response()
  def ping(client) do
    with_api(client, :ping, & &1.ping(client))
  end

  @doc """
  Verifies the API token by sending a request to the DB instance.

  ## Examples

      iex> client = EventSourcingDB.Client.new("http://localhost:3000", "secrettoken")
      iex> EventSourcingDB.verify_api_token(client)
      :ok
  """
  @spec verify_api_token(Client.t()) :: primitive_response()
  def verify_api_token(client) do
    with_api(client, & &1.verify_api_token(client))
  end

  @doc """
  Writing Events

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
       query: "FROM e IN events WHERE e.type == 'io.eventsourcingdb.library.book-borrowed'
       PROJECT INTO COUNT() < 10"
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

  If the write fails in a way that leaves open whether EventSourcingDB stored it, for example because the connection stalled or broke after the request was sent, the function returns an `EventSourcingDB.Errors.OutcomeUnknown`, which holds the error as its `cause`. EventSourcingDB never stores a write halfway, so before you repeat it, find out whether it was stored, for example by reading the events of the subject. Every other error means that the events were not stored.
  """
  @spec write_events(Client.t(), nonempty_list(EventCandidate.t()), [precondition()]) ::
          response(Event.t())
  def write_events(client, events, preconditions \\ []) when is_list(events) do
    with_api(client, & &1.write_events(client, events, preconditions))
  end

  @spec write_events!(Client.t(), nonempty_list(EventCandidate.t()), [precondition()]) ::
          response!(Event.t())
  def write_events!(client, events, preconditions \\ []) when is_list(events) do
    unwrap!(write_events(client, events, preconditions))
  end

  @doc """
  Reading Events

  To read all events of a subject, call the `read_events` function with the subject and an options struct.

  The function returns a stream from which you can retrieve one event at a time:

  ```elixir
  case EventSourcingDB.read_events(client, "/books/42") do
    {:ok, events} -> Enum.to_list(events)
    {:error, reason} -> # ...
  end
  ```

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the stall timeout of the client (see `EventSourcingDB.Client`), an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

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

  """
  @spec read_events(Client.t(), String.t(), ReadEventsOptions.t() | nil) ::
          stream_response(Event.t())
  def read_events(client, subject, options \\ nil) do
    with_api(client, & &1.read_events(client, subject, options))
  end

  @spec read_events!(Client.t(), String.t(), ReadEventsOptions.t() | nil) ::
          stream_response!(Event.t())
  def read_events!(client, subject, options \\ nil) do
    unwrap!(read_events(client, subject, options))
  end

  @doc """
  Observing Events

  To observe all events of a subject, call the `observe_events` function with the subject.

  The function returns a stream from which you can retrieve one event at a time:

  ```elixir
  case EventSourcingDB.observe_events(client, "/books/42") do
    {:ok, events} -> Enum.to_list(events)
    {:error, reason} -> # ...
  end
  ```

  While there are no events to deliver, EventSourcingDB sends a heartbeat every second. If neither an event nor a heartbeat arrives for the stall timeout of the client (see `EventSourcingDB.Client`), 30 seconds by default, the stream closes the connection and raises an `EventSourcingDB.Errors.ConnectionStalled` error.

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

  """
  @spec observe_events(Client.t(), String.t(), ObserveEventsOptions.t() | nil) ::
          stream_response(Event.t())
  def observe_events(client, subject, options \\ nil) do
    with_api(client, & &1.observe_events(client, subject, options))
  end

  @spec observe_events!(Client.t(), String.t(), ObserveEventsOptions.t() | nil) ::
          stream_response!(Event.t())
  def observe_events!(client, subject, options \\ nil) do
    unwrap!(observe_events(client, subject, options))
  end

  @doc """
  Running EventQL Queries

  To run an EventQL query, call the `run_eventql_query` function and provide the query as argument. The function returns a stream:

  ```elixir
  case EventSourcingDB.run_eventql_query(client, "FROM e IN events PROJECT INTO e") do
    {:ok, rows} -> Enum.to_list(rows)
    {:error, reason} -> # ...
  end
  ```

  *Note that each row returned by the stream matches the projection specified in your query.*

  While there are no rows to deliver, EventSourcingDB sends a heartbeat every second. If neither a row nor a heartbeat arrives for the stall timeout of the client (see `EventSourcingDB.Client`), 30 seconds by default, the stream closes the connection and raises an `EventSourcingDB.Errors.ConnectionStalled` error.

  If anything else goes wrong while you enumerate the stream, the stream closes the connection as well and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

  """
  @spec run_eventql_query(Client.t(), String.t()) :: stream_response(any())
  def run_eventql_query(client, query) do
    with_api(client, & &1.run_eventql_query(client, query))
  end

  @spec run_eventql_query!(Client.t(), String.t()) :: stream_response!(any())
  def run_eventql_query!(client, query) do
    unwrap!(run_eventql_query(client, query))
  end

  @doc """
  Registering an Event Schema

  To register an event schema, call the `register_event_schema` function and hand over an event type and the desired schema:

  ```elixir
  EventSourcingDB.register_event_schema(
    "io.eventsourcingdb.library.book-acquired",
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

  As for writing events, the function returns an `EventSourcingDB.Errors.OutcomeUnknown` if it fails in a way that leaves open whether EventSourcingDB registered the schema, and an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB refuses it, for example with the code `EventSourcingDB.ErrorCode.event_schema_already_registered/0`.
  """
  @spec register_event_schema(Client.t(), String.t(), map()) :: response(ManagementEvent.t())
  def register_event_schema(client, event_type, schema) do
    ExJsonSchema.Schema.resolve(schema)
    with_api(client, & &1.register_event_schema(client, event_type, schema))
  end

  @spec register_event_schema!(Client.t(), String.t(), map()) :: response!(ManagementEvent.t())
  def register_event_schema!(client, event_type, schema) do
    unwrap!(register_event_schema(client, event_type, schema))
  end

  @doc """
  Reading Subjects

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

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the stall timeout of the client (see `EventSourcingDB.Client`), an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

  If you only want to list subjects within a specific branch, provide the desired subject instead. With `recursive` set to `false`, the stream contains the subject alone, if it exists:

  ```elixir
  EventSourcingDB.read_subjects(
    client,
    "/books",
    %EventSourcingDB.ReadSubjectsOptions{recursive: false}
  )
  ```

  The options are required. Without a `recursive` option of `true` or `false`, the function raises an `ArgumentError`.
  """
  @spec read_subjects(Client.t(), String.t(), ReadSubjectsOptions.t()) ::
          stream_response(String.t())
  def read_subjects(client, subject, options) do
    recursive = recursive!(options)
    with_api(client, & &1.read_subjects(client, subject, recursive))
  end

  @spec read_subjects!(Client.t(), String.t(), ReadSubjectsOptions.t()) ::
          stream_response!(String.t())
  def read_subjects!(client, subject, options) do
    unwrap!(read_subjects(client, subject, options))
  end

  defp recursive!(%ReadSubjectsOptions{recursive: recursive}) when is_boolean(recursive),
    do: recursive

  defp recursive!(options) do
    raise ArgumentError,
          "expected the options of read_subjects to be an EventSourcingDB.ReadSubjectsOptions " <>
            "struct whose :recursive is true or false, got: #{inspect(options)}"
  end

  @doc """
  Reading a Specific Event Type

  To read a specific event type, call the `read_event_type` function with the event type as an argument. The function returns the detailed event type, which includes the schema:

  ```elixir
  case EventSourcingDB.read_event_type(client, "io.eventsourcingdb.library.book-acquired") do
    {:ok, event_type} -> # ...
    {:error, reason} -> # ...
  end
  ```
  """
  @spec read_event_type(Client.t(), String.t()) :: response(EventType.t())
  def read_event_type(client, event_type) do
    with_api(client, & &1.read_event_type(client, event_type))
  end

  @spec read_event_type!(Client.t(), String.t()) :: response!(EventType.t())
  def read_event_type!(client, event_type) do
    unwrap!(read_event_type(client, event_type))
  end

  @doc """
  Reading Event Types

  To list all event types, call the `read_event_types` function. The function returns a stream from which you can retrieve one event type at a time:

  ```elixir
  case EventSourcingDB.read_event_types(client) do
    {:ok, event_types} -> Enum.to_list(event_types)
    {:error, reason} -> # ...
  end
  ```

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DbApiError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.ConnectionStalled` if nothing arrives for the stall timeout of the client (see `EventSourcingDB.Client`), an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.
  """
  @spec read_event_types(Client.t()) :: stream_response(EventType.t())
  def read_event_types(client) do
    with_api(client, & &1.read_event_types(client))
  end

  @spec read_event_types!(Client.t()) :: stream_response!(EventType.t())
  def read_event_types!(client) do
    unwrap!(read_event_types(client))
  end

  #
  # region Requests
  #

  # Runs the call on the API that the client talks to the server through.
  defp with_api(client, kind \\ :other, call) do
    case Transport.api(client, kind) do
      {:ok, api} -> call.(api)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: raise(reason)
end
