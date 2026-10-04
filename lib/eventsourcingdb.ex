defmodule EventSourcingDB do
  @moduledoc """
  `EventSourcingDB` client SDK.
  """

  alias EventSourcingDB.{
    ObserveEventsOptions,
    ReadEventsOptions,
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

  alias EventSourcingDB.Errors.{
    ApiError,
    DBError,
    HeartbeatTimeout,
    InvalidServerHeader,
    InvalidResponseType,
    TransmissionError
  }

  alias EventSourcingDB.Requests.{
    ObserveEvents,
    Ping,
    ReadEvents,
    ReadEventType,
    ReadEventTypes,
    ReadSubjects,
    RegisterEventSchema,
    RunEventQL,
    VerifyApiToken,
    WriteEvents
  }

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
    request_one_shot(client, Ping.new())
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
    request_one_shot(client, VerifyApiToken.new())
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

  """
  @spec write_events(Client.t(), nonempty_list(EventCandidate.t()), [precondition()]) ::
          response(Event.t())
  def write_events(client, events, preconditions \\ []) when is_list(events) do
    request_one_shot(client, WriteEvents.new(events, preconditions))
  end

  @spec write_events!(Client.t(), nonempty_list(EventCandidate.t()), [precondition()]) ::
          response!(Event.t())
  def write_events!(client, events, preconditions \\ []) when is_list(events) do
    request_one_shot!(client, WriteEvents.new(events, preconditions))
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

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DBError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

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
    request_stream(client, ReadEvents.new(subject, options))
  end

  @spec read_events!(Client.t(), String.t(), ReadEventsOptions.t() | nil) ::
          stream_response!(Event.t())
  def read_events!(client, subject, options \\ nil) do
    request_stream!(client, ReadEvents.new(subject, options))
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

  While there are no events to deliver, EventSourcingDB sends a heartbeat every second. If neither an event nor a heartbeat arrives for 30 seconds, the stream closes the connection and raises an `EventSourcingDB.Errors.HeartbeatTimeout` error.

  If anything else goes wrong while you enumerate the stream, the stream closes the connection as well and raises the corresponding error: an `EventSourcingDB.Errors.DBError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

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
    request_stream(client, ObserveEvents.new(subject, options))
  end

  @spec observe_events!(Client.t(), String.t(), ObserveEventsOptions.t() | nil) ::
          stream_response!(Event.t())
  def observe_events!(client, subject, options \\ nil) do
    request_stream!(client, ObserveEvents.new(subject, options))
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

  While there are no rows to deliver, EventSourcingDB sends a heartbeat every second. If neither a row nor a heartbeat arrives for 30 seconds, the stream closes the connection and raises an `EventSourcingDB.Errors.HeartbeatTimeout` error.

  If anything else goes wrong while you enumerate the stream, the stream closes the connection as well and raises the corresponding error: an `EventSourcingDB.Errors.DBError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

  """
  @spec run_eventql_query(Client.t(), String.t()) :: stream_response(any())
  def run_eventql_query(client, query) do
    request_stream(client, RunEventQL.new(query))
  end

  @spec run_eventql_query!(Client.t(), String.t()) :: stream_response!(any())
  def run_eventql_query!(client, query) do
    request_stream!(client, RunEventQL.new(query))
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
  """
  @spec register_event_schema(Client.t(), String.t(), map()) :: response(ManagementEvent.t())
  def register_event_schema(client, event_type, schema) do
    request_one_shot(client, RegisterEventSchema.new(event_type, schema))
  end

  @spec register_event_schema!(Client.t(), String.t(), map()) :: response!(ManagementEvent.t())
  def register_event_schema!(client, event_type, schema) do
    request_one_shot!(client, RegisterEventSchema.new(event_type, schema))
  end

  @doc """
  Reading Subjects

  To list all subjects, call the `read_subjects` function with `/` as the base subject. The function returns a stream from which you can retrieve one subject at a time:

  ```elixir
  case EventSourcingDB.read_subjects(client, "/") do
    {:ok, subjects} -> Enum.to_list(subjects)
    {:error, reason} -> # ...
  end
  ```

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DBError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.

  If you only want to list subjects within a specific branch, provide the desired base subject instead:

  ```elixir
  EventSourcingDB.read_subjects(client, "/books")
  ```
  """
  @spec read_subjects(Client.t(), String.t()) :: stream_response(String.t())
  def read_subjects(client, base_subject) do
    request_stream(client, ReadSubjects.new(base_subject))
  end

  @spec read_subjects!(Client.t(), String.t()) :: stream_response!(String.t())
  def read_subjects!(client, base_subject) do
    request_stream!(client, ReadSubjects.new(base_subject))
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
    request_one_shot(client, ReadEventType.new(event_type))
  end

  @spec read_event_type!(Client.t(), String.t()) :: response!(EventType.t())
  def read_event_type!(client, event_type) do
    request_one_shot!(client, ReadEventType.new(event_type))
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

  If something goes wrong while you enumerate the stream, the stream closes the connection and raises the corresponding error: an `EventSourcingDB.Errors.DBError` if EventSourcingDB reports an error, an `EventSourcingDB.Errors.TransmissionError` if the connection fails, an `EventSourcingDB.Errors.InvalidResponseType` if the response contains an item of an unexpected type, or a `Jason.DecodeError` if the response is not valid JSON.
  """
  @spec read_event_types(Client.t()) :: stream_response(EventType.t())
  def read_event_types(client) do
    request_stream(client, ReadEventTypes.new())
  end

  @spec read_event_types!(Client.t()) :: stream_response!(EventType.t())
  def read_event_types!(client) do
    request_stream!(client, ReadEventTypes.new())
  end

  #
  # region Requests
  #

  # Streams with heartbeats end with a HeartbeatTimeout error if neither a line
  # nor a heartbeat arrives for this many milliseconds. The value is fixed, only
  # the tests shorten it through the application environment.
  @heartbeat_timeout 30_000

  # Finch waits this many milliseconds for data, unless the client sets a
  # receive timeout of its own.
  @receive_timeout 15_000

  @spec request_stream!(Client.t(), struct()) :: stream_response!(any())
  defp request_stream!(client, request) do
    result = request_stream(client, request)

    case result do
      {:ok, stream} -> stream
      {:error, reason} -> raise(reason)
    end
  end

  @spec request_stream(Client.t(), struct()) :: stream_response(any())
  defp request_stream(client, request) do
    req = build_request(client, request)

    case open_stream(req, request) do
      {:ok, response} ->
        line_timeout = line_timeout(req, request)

        # The resource receives the lines of the response, and keeps the start
        # of a line that has not arrived completely yet next to the response.
        # Errors while the stream is read are raised, also while a line is
        # handled, so the stream always hands the response to the cleanup,
        # which closes the connection.
        stream =
          Stream.resource(
            fn -> {response, ""} end,
            fn state -> receive_lines(state, request, line_timeout) end,
            fn {response, _rest} -> close_stream(response) end
          )
          |> Stream.flat_map(&handle_line(&1, request))

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec open_stream(Req.Request.t(), struct()) :: response(Req.Response.t())
  defp open_stream(req, request) do
    receive_timeout = receive_timeout(req, request)

    response =
      if finch_bounds_each_wait?(req) do
        Req.request(req, stream_options(request))
      else
        request_through_relay(req, receive_timeout)
      end

    with :ok <- validate_transmission(response) do
      validate_stream_response(response, receive_timeout)
    end
  end

  # A stream that fails to open closes its response right away, so that none
  # of its messages stay behind in the mailbox.
  defp validate_stream_response({:ok, response} = result, receive_timeout) do
    with :ok <- validate_server_headers(result),
         :ok <- validate_stream_status(response, receive_timeout) do
      {:ok, response}
    else
      error ->
        close_stream(response)
        error
    end
  end

  # For a status other than 200, the error carries the text that the server
  # sent, as for the one-shot requests, so the body is read before the
  # response is closed.
  defp validate_stream_status(%Req.Response{status: 200}, _receive_timeout), do: :ok

  defp validate_stream_status(response, receive_timeout) do
    case read_body(response, receive_timeout, "") do
      {:ok, body} -> {:error, %ApiError{reason: body}}
      {:error, reason} -> {:error, %TransmissionError{reason: reason}}
    end
  end

  # Reads the rest of the body, and waits for each block of it at most for the
  # receive timeout.
  defp read_body(response, receive_timeout, body) do
    case receive_message(response, deadline(receive_timeout)) do
      {:ok, [data: data]} -> read_body(response, receive_timeout, body <> data)
      {:ok, [:done]} -> {:ok, body}
      {:ok, _other} -> read_body(response, receive_timeout, body)
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  # The heartbeat timeout watches streams with heartbeats, so the socket must not
  # time out before it does (Req defaults to 15 seconds). The socket's receive
  # timeout still bounds the wait for the response headers.
  defp stream_options(request) do
    case heartbeat_timeout(request) do
      :infinity -> [into: :self]
      timeout -> [into: :self, receive_timeout: 2 * timeout]
    end
  end

  # Every call waits for the next lines with a new deadline, so every line,
  # including a heartbeat, restarts the heartbeat timeout. The data of the
  # response arrives in blocks, which need not match the lines: a block may
  # hold several lines, and a long line may span several blocks. So the start
  # of a line waits in the state until the rest of it arrives. It is not a line
  # yet, so it does not restart the heartbeat timeout.
  #
  # Errors are raised rather than returned, because Stream.resource takes a
  # returned {:error, reason} for a list of items. Raising ends the stream,
  # which cancels the response and thereby closes the connection.
  defp receive_lines({response, :done}, _request, _line_timeout) do
    {:halt, {response, :done}}
  end

  defp receive_lines({response, rest}, request, line_timeout) do
    receive_lines(response, rest, request, deadline(line_timeout))
  end

  defp receive_lines(response, rest, request, deadline) do
    case receive_message(response, deadline) do
      {:ok, [data: data]} ->
        case split_lines(rest, data) do
          {[], rest} -> receive_lines(response, rest, request, deadline)
          {lines, rest} -> {lines, {response, rest}}
        end

      # EventSourcingDB ends every line with a newline, including the last one.
      # Still, a rest at the end of the response is a line as well.
      {:ok, [:done]} ->
        {lines, ""} = split_lines(rest, "\n")
        {lines, {response, :done}}

      # Other messages of the response, such as trailing headers, carry no
      # line.
      {:ok, _other} ->
        receive_lines(response, rest, request, deadline)

      {:error, reason} ->
        raise(%TransmissionError{reason: reason})

      :timeout ->
        raise(timeout_error(request))
    end
  end

  # Splits the data at each newline into the lines it completes, the first of
  # which begins with the rest of the data before, and a new rest, the start of
  # a line whose newline has not arrived yet. Empty lines are skipped, and data
  # without a newline, such as the empty data frame with which EventSourcingDB
  # ends a response over HTTP/2, completes no line.
  defp split_lines(rest, data) do
    [first | others] = String.split(data, "\n")
    {lines, [rest]} = Enum.split([rest <> first | others], -1)

    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp handle_line(line, request) do
    json = Jason.decode(line)

    # evaluate message
    result = evaluate_message(json, request)

    # process the evaluated result
    case result do
      # push forward into the consumer stream
      {:ok, message} -> [message]
      {:error, reason} -> raise(reason)
      # handle heartbeat case
      nil -> []
    end
  end

  # Waits for the next message of the response. Finch tags every message of the
  # response with the reference of the request, so only these are received,
  # and all other messages of the process stay in its mailbox. They are not a
  # line, so they do not restart the heartbeat timeout either.
  defp receive_message(%Req.Response{body: %Req.Response.Async{ref: ref}} = response, deadline) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          # Req does not recognise every message of the response, for example
          # trailing headers over HTTP/2. They carry no line, so they are
          # skipped.
          :unknown -> receive_message(response, deadline)
          result -> result
        end
    after
      remaining_time(deadline) -> :timeout
    end
  end

  # Closes the connection, and cleans up the messages of the response that are
  # left in the mailbox.
  defp close_stream(response) do
    case Req.Response.get_private(response, :relay) do
      nil -> :ok
      relay -> stop_relay(relay, Process.monitor(relay))
    end

    Req.cancel_async_response(response)
  end

  # How long a stream waits for the next line. For streams with heartbeats,
  # this is the heartbeat timeout. For other streams, Finch bounds each wait
  # for data with the receive timeout, unless the stream has to bound it
  # itself (see request_through_relay/2).
  defp line_timeout(req, request) do
    case heartbeat_timeout(request) do
      :infinity ->
        if finch_bounds_each_wait?(req), do: :infinity, else: receive_timeout(req, request)

      timeout ->
        timeout
    end
  end

  defp timeout_error(request) do
    if get_request_module(request).heartbeats?() do
      %HeartbeatTimeout{}
    else
      %TransmissionError{reason: %Req.TransportError{reason: :timeout}}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining_time(:infinity), do: :infinity
  defp remaining_time(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp heartbeat_timeout(request) do
    if get_request_module(request).heartbeats?() do
      Application.get_env(:eventsourcingdb, :heartbeat_timeout, @heartbeat_timeout)
    else
      :infinity
    end
  end

  # The receive timeout bounds each wait for data, including the wait for the
  # response headers. For streams with heartbeats, it must not end the stream
  # before the heartbeat timeout does (see stream_options/1).
  defp receive_timeout(req, request) do
    case heartbeat_timeout(request) do
      :infinity -> Req.Request.get_option(req, :receive_timeout, @receive_timeout)
      timeout -> 2 * timeout
    end
  end

  # Finch bounds each wait for data with the receive timeout only in an HTTP/1
  # pool, and the whole request in an HTTP/2 pool. Req starts an HTTP/2 pool if
  # the protocols leave out HTTP/1 (with both, the protocol is negotiated per
  # connection within an HTTP/1 pool). The protocols of a pool that the client
  # brings by name are unknown, so the stream bounds each wait itself there,
  # whether the pool speaks HTTP/1 or HTTP/2.
  defp finch_bounds_each_wait?(req) do
    case Req.Request.get_option(req, :finch) do
      nil ->
        http1_pool?(req, [])

      options when is_list(options) ->
        not Keyword.has_key?(options, :name) and http1_pool?(req, options)

      _name ->
        false
    end
  end

  # Req takes the protocols from the Finch options, or else from the connection
  # options.
  defp http1_pool?(req, finch_options) do
    protocols =
      Keyword.get_lazy(finch_options, :protocols, fn ->
        Req.Finch.pool_options(req.options)[:protocols]
      end)

    :http1 in protocols
  end

  defp evaluate_message(message, request) do
    request_module = get_request_module(request)
    expected_type = request_module.type()

    case message do
      {:ok, %{"type" => type, "payload" => payload}} ->
        case type do
          # This is the expected type, so we try to parse it.
          ^expected_type ->
            {:ok, request_module.process(payload)}

          # Forward Errors from the DB as %DBError{}
          "error" ->
            {:error, %DBError{payload: payload}}

          # Ignore heartbeat messages.
          "heartbeat" ->
            nil

          other ->
            {:error, %InvalidResponseType{expected: expected_type, actual: other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request_one_shot(Client.t(), struct()) :: response(any())
  defp request_one_shot(client, request) do
    request_module = get_request_module(request)

    response =
      client
      |> build_request(request)
      |> Req.request()

    # credo warns the last two statements have the same error signature and can
    # therefore be combined. This was a design choice on purpose to have
    # dedicated function to validate response and request body respectively.
    # credo:disable-for-lines:2
    result =
      with :ok <- validate_transmission(response),
           :ok <- validate_server_headers(response),
           :ok <- validate_request_response(response, request_module),
           {:ok, resp} <- validate_response(response),
           {:ok, data} <- validate_request_body(resp.body, request_module) do
        {:ok, data}
      end

    case result do
      {:ok, nil} -> :ok
      _ -> result
    end
  end

  @spec request_one_shot!(Client.t(), struct()) :: any()
  defp request_one_shot!(client, request) do
    result = request_one_shot(client, request)

    case result do
      {:ok, data} -> data
      {:error, reason} -> raise(reason)
    end
  end

  #
  # region Relay
  #

  # Over HTTP/2, Finch bounds a whole request with the receive timeout, rather
  # than each wait for data, so a stream that runs for longer would end while
  # data still arrives. So the stream asks Finch for no timeout, and bounds
  # each wait itself: the wait for the response headers here, and the wait for
  # each line in receive_lines/3. Req then waits for the response headers in a
  # receive without any bound, which the caller can not interrupt, so the
  # request runs in a relay process, which forwards the messages of the
  # response to the caller, while the caller bounds the wait. A pool that the
  # client brings by name takes this path as well, even one that speaks
  # HTTP/1, where Finch then waits for data without a bound, too.
  #
  # The relay is linked to the caller while it waits for the response headers,
  # and monitors it afterwards, so it does not outlive the caller. Finch in turn
  # cancels the request once the relay is down.
  defp request_through_relay(req, timeout) do
    caller = self()
    relay = spawn_link(fn -> run_relay(caller, req) end)
    monitor = Process.monitor(relay)

    receive do
      {^relay, result} ->
        Process.demonitor(monitor, [:flush])
        relay_result(relay, result)

      {:DOWN, ^monitor, :process, ^relay, reason} ->
        exit(reason)
    after
      timeout ->
        Process.unlink(relay)
        stop_relay(relay, monitor)
        discard_relay_result(relay)
        {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  defp relay_result(relay, {:ok, response}) do
    {:ok, Req.Response.put_private(response, :relay, relay)}
  end

  defp relay_result(_relay, {:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp relay_result(_relay, result), do: result

  # Once the relay is down, every message it forwarded is in the mailbox.
  defp stop_relay(relay, monitor) do
    Process.exit(relay, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^relay, _reason} -> :ok
    end
  end

  # The relay may have sent its result just before it was stopped.
  defp discard_relay_result(relay) do
    receive do
      {^relay, {:ok, response}} -> Req.cancel_async_response(response)
      {^relay, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp run_relay(caller, req) do
    monitor = Process.monitor(caller)

    result =
      try do
        Req.request(req, into: :self, receive_timeout: :infinity)
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    # From here on, the monitor watches the caller, and the link would only
    # leave an exit message for a caller that traps exits.
    Process.unlink(caller)
    send(caller, {self(), result})

    case result do
      {:ok, %Req.Response{body: %Req.Response.Async{ref: ref}}} -> forward(caller, monitor, ref)
      _other -> :ok
    end
  end

  # Forwards the messages of the response to the caller until the response
  # ends, or until the caller is down.
  defp forward(caller, monitor, ref) do
    receive do
      {^ref, :done} = message ->
        send(caller, message)

      {^ref, {:error, _reason}} = message ->
        send(caller, message)

      {^ref, _} = message ->
        send(caller, message)
        forward(caller, monitor, ref)

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        :ok
    end
  end

  #
  # region Request Builder
  #

  @spec build_request(Client.t(), struct()) :: Req.Request.t()
  defp build_request(client, request) do
    request_module = get_request_module(request)
    method = request_module.method()

    opts =
      [
        base_url: client.base_url,
        auth: {:bearer, client.api_token},
        method: method,
        url: request_module.path()
      ]
      |> Keyword.merge(build_body_opts(request, method))
      |> Keyword.merge(client.req_options)

    Req.new(opts)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_struct(mod) do
    implements_protocol?(protocol, mod.__struct__)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_atom(mod) do
    protocol.impl_for(mod) != nil
  end

  # GET requests must not carry a body, otherwise Req turns them into POST
  # requests (see the encode_body step, introduced in Req 0.7).
  defp build_body_opts(_request_module, :get), do: []

  defp build_body_opts(request_module, _method) do
    if implements_protocol?(Jason.Encoder, request_module) do
      [
        headers: [{"Content-Type", "application/json"}],
        json: request_module
      ]
    else
      []
    end
  end

  #
  # region Response Validation
  #

  @spec validate_transmission({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          :ok | {:error, TransmissionError.t()}
  defp validate_transmission({:error, reason}) do
    {:error, %TransmissionError{reason: reason}}
  end

  defp validate_transmission({:ok, _}), do: :ok

  @spec validate_server_headers({:ok, Req.Response.t()}) ::
          :ok | {:error, InvalidServerHeader.t()}
  defp validate_server_headers({:ok, response}) do
    if response
       |> Req.Response.get_header("Server")
       |> Enum.any?(fn val -> String.starts_with?(val, "EventSourcingDB/") end) do
      :ok
    else
      {:error, %InvalidServerHeader{}}
    end
  end

  defp validate_response({:ok, %{status: 200} = response}) do
    {:ok, response}
  end

  defp validate_response({:ok, %{body: body}}) do
    {:error, %ApiError{reason: body}}
  end

  defp validate_request_response(response, request_module) do
    request_module.validate_response(response)
  end

  defp validate_request_body(body, request_module) do
    result = request_module.validate_body(body)

    case result do
      :ok -> {:ok, nil}
      _ -> result
    end
  end

  defp get_request_module(struct) when is_struct(struct) do
    struct.__struct__
  end

  defp get_request_module(module) do
    module
  end
end
