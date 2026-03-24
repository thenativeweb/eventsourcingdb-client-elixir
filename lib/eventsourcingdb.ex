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
      from_latest_event: %EventSourcingDB.FromLatestEventOptions{
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
      from_latest_event: %EventSourcingDB.FromLatestEventOptions{
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
    case open_stream(client, request) do
      {:ok, response} ->
        stream =
          Stream.resource(
            fn -> response end,
            fn response -> handle_stream(response, request) end,
            fn
              %Req.Response{} = resp ->
                Req.cancel_async_response(resp)

              other ->
                other
            end
          )

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec open_stream(Client.t(), struct()) :: response(any())
  defp open_stream(client, request) do
    response =
      client
      |> build_request(request)
      |> Req.request(into: :self)

    # credo warns the last two statements to be redundant, but I can't figure
    # out why it says so (they aren't)
    # credo:disable-for-lines:1
    with {:ok} <- validate_transmission(response),
         {:ok} <- validate_server_headers(response),
         {:ok, resp} <- validate_response(response) do
      {:ok, resp}
    end
  end

  defp handle_stream(response, request) do
    case Req.parse_message(
           response,
           receive do
             message -> message
           end
         ) do
      {:ok, [data: chunk]} ->
        json = Jason.decode(chunk)

        # evaluate message
        result = evaluate_message(json, request)

        # process the evaluated result
        case result do
          # push forward into the consumer stream
          {:ok, message} ->
            {[message], response}

          {:error, reason} ->
            raise(reason)

          # handle heartbeat case
          nil ->
            {[], response}
        end

      {:error, reason} ->
        raise(reason)

      # This is returned when the stream is done.
      {:ok, [:done]} ->
        {:halt, response}

      # This is received inside Finch from a process that is not the socket.
      # Ideally Req should be able to handle this and return a proper error or ignore it.
      :unknown ->
        {[], response}

      _something_else ->
        {[], response}
    end
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
      with {:ok} <- validate_transmission(response),
           {:ok} <- validate_server_headers(response),
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
  # region Request Builder
  #

  @spec build_request(Client.t(), struct()) :: Req.Request.t()
  defp build_request(client, request) do
    request_module = get_request_module(request)

    opts =
      [
        base_url: client.base_url,
        auth: {:bearer, client.api_token},
        method: request_module.method(),
        url: request_module.path()
      ]
      |> Keyword.merge(build_body_opts(request))
      |> Keyword.merge(client.req_options)

    Req.new(opts)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_struct(mod) do
    implements_protocol?(protocol, mod.__struct__)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_atom(mod) do
    protocol.impl_for(mod) != nil
  end

  defp build_body_opts(request_module) do
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

  defp validate_transmission({:error, reason}) do
    {:error, %TransmissionError{reason: reason}}
  end

  defp validate_transmission({:ok, _}), do: {:ok}

  @spec validate_server_headers({:ok, Req.Response.t()}) ::
          {:ok} | {:error, InvalidServerHeader.t()}
  defp validate_server_headers({:ok, response}) do
    if response
       |> Req.Response.get_header("Server")
       |> Enum.any?(fn val -> String.starts_with?(val, "EventSourcingDB/") end) do
      {:ok}
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
