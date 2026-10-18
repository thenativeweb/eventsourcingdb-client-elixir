defmodule EventSourcingDB.Transport.V1 do
  @moduledoc false

  # The v1 API, which servers offer up to EventSourcingDB 1.2.

  @behaviour EventSourcingDB.Transport.API

  alias EventSourcingDB.{ErrorCode, Event, EventType, ManagementEvent, RawJSON}

  alias EventSourcingDB.Errors.{
    DbApiError,
    InvalidEventType,
    InvalidResponseType,
    PingFailed,
    TransmissionError
  }

  alias EventSourcingDB.Transport.{HTTP, WriteOutcome}

  #
  # region Requests with a single answer
  #

  @impl true
  def ping(client) do
    with {:ok, body} <- request(client, :ping, :get, "/api/v1/ping", nil) do
      case body do
        %{"type" => "io.eventsourcingdb.api.ping-received"} -> :ok
        _other -> {:error, %PingFailed{}}
      end
    end
  end

  @impl true
  def verify_api_token(client) do
    with {:ok, body} <- request(client, :verify_api_token, :post, "/api/v1/verify-api-token", %{}) do
      case body do
        %{"type" => "io.eventsourcingdb.api.api-token-verified"} -> :ok
        _other -> {:error, %InvalidEventType{}}
      end
    end
  end

  @impl true
  def write_events(client, events, preconditions) do
    body = %{events: events, preconditions: preconditions}

    client
    |> HTTP.one_shot(:post, "/api/v1/write-events", body)
    |> text_body(:write_events)
    |> then(fn result -> with {:ok, text} <- result, do: written_events(text) end)
    |> WriteOutcome.classify(:v1)
  end

  # Each event keeps the text of its data as it arrived, for verifying its
  # hash. Should the texts not match the events, the events verify their hash
  # as Jason encodes their data again, rather than any event get lost.
  defp written_events(text) do
    case Jason.decode(text) do
      {:ok, items} when is_list(items) ->
        raw_data = text |> RawJSON.elements() |> Enum.map(&RawJSON.member(&1, "data"))

        raw_data =
          if length(raw_data) == length(items),
            do: raw_data,
            else: List.duplicate(nil, length(items))

        {:ok, Enum.zip_with(items, raw_data, &Event.new/2)}

      {:ok, _other} ->
        {:error, %InvalidResponseType{expected: "a list of events", actual: text}}

      {:error, reason} ->
        {:error, %TransmissionError{reason: reason}}
    end
  end

  @impl true
  def register_event_schema(client, event_type, schema) do
    body = %{eventType: event_type, schema: schema}

    client
    |> request(:register_event_schema, :post, "/api/v1/register-event-schema", body)
    |> then(fn result -> with {:ok, body} <- result, do: schema_registered(body) end)
    |> WriteOutcome.classify(:v1)
  end

  # The v1 API names the type of the schema eventType.
  defp schema_registered(%{"type" => "io.eventsourcingdb.api.event-schema-registered"} = body) do
    {:ok, ManagementEvent.new(Map.update(body, "data", nil, &rename_event_type/1))}
  end

  defp schema_registered(_body), do: {:error, %InvalidEventType{}}

  defp rename_event_type(%{"eventType" => type} = data) do
    data |> Map.delete("eventType") |> Map.put("type", type)
  end

  defp rename_event_type(data), do: data

  @impl true
  def read_event_type(client, event_type) do
    with {:ok, body} <-
           request(client, :read_event_type, :post, "/api/v1/read-event-type", %{
             eventType: event_type
           }) do
      {:ok, event_type(body)}
    end
  end

  defp request(client, operation, method, path, body) do
    client
    |> HTTP.one_shot(method, path, body)
    |> text_body(operation)
    |> then(fn result -> with {:ok, text} <- result, do: decode(text) end)
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, %TransmissionError{reason: reason}}
    end
  end

  defp text_body({:ok, %Req.Response{status: 200, body: text}}, _operation), do: {:ok, text}

  defp text_body({:ok, %Req.Response{body: text} = response}, operation),
    do: {:error, status_error(operation, response, text)}

  defp text_body({:error, reason}, _operation), do: {:error, reason}

  #
  # region Errors
  #

  # The v1 API reports an error as a status and a text, without a code. For
  # the errors that clearly match a code of the v2 API, the error gets that
  # code, as the texts of EventSourcingDB 1.2 tell them apart.
  @operation_mode_conflict "the current operation mode conflicts with the given request"

  defp status_error(operation, response, text) do
    DbApiError.from_response(response, text, code(operation, response.status, text))
  end

  defp code(_operation, 503, @operation_mode_conflict <> _rest), do: ErrorCode.store_read_only()

  defp code(:write_events, 409, "state conflict" <> _rest),
    do: ErrorCode.precondition_violated()

  defp code(:write_events, 409, "schema conflict" <> _rest),
    do: ErrorCode.event_schema_violated()

  defp code(:write_events, 507, _text), do: ErrorCode.license_invalid()

  defp code(:register_event_schema, 409, text) do
    if String.trim_trailing(text, "\n") == "schema conflict: schema already exists",
      do: ErrorCode.event_schema_already_registered()
  end

  defp code(:read_event_type, 404, _text), do: ErrorCode.event_type_unknown()
  defp code(_operation, _status, _text), do: nil

  # An error that the server reports within a stream, after it answered with
  # status 200, carries only its text.
  defp item_error(%{"error" => text}) when is_binary(text) do
    %DbApiError{description: text, status: 200}
  end

  defp item_error(payload), do: %DbApiError{description: inspect(payload), status: 200}

  #
  # region Streams
  #

  @impl true
  def read_events(client, subject, options) do
    stream(client, :read_events, "/api/v1/read-events", subject_body(subject, options),
      type: "event",
      process: &event/2,
      heartbeats?: false
    )
  end

  @impl true
  def observe_events(client, subject, options) do
    # The server sends a heartbeat every second while there is nothing else to
    # send.
    stream(client, :observe_events, "/api/v1/observe-events", subject_body(subject, options),
      type: "event",
      process: &event/2,
      heartbeats?: true
    )
  end

  @impl true
  def run_eventql_query(client, query) do
    # The server sends a heartbeat every second while there is nothing else to
    # send.
    stream(client, :run_eventql_query, "/api/v1/run-eventql-query", %{query: query},
      type: "row",
      process: fn row, _line -> row end,
      heartbeats?: true
    )
  end

  # The v1 API always reads recursively, from the subject on, so reading the
  # subject alone keeps only the subject itself.
  @impl true
  def read_subjects(client, subject, recursive) do
    result =
      stream(client, :read_subjects, "/api/v1/read-subjects", %{baseSubject: subject},
        type: "subject",
        process: fn payload, _line -> payload["subject"] end,
        heartbeats?: false
      )

    case result do
      {:ok, subjects} when not recursive -> {:ok, Stream.filter(subjects, &(&1 == subject))}
      result -> result
    end
  end

  @impl true
  def read_event_types(client) do
    stream(client, :read_event_types, "/api/v1/read-event-types", %{},
      type: "eventType",
      process: fn payload, _line -> event_type(payload) end,
      heartbeats?: false
    )
  end

  defp stream(client, operation, path, body, options) do
    HTTP.stream(client, :post, path, body,
      decode: decoder(Keyword.fetch!(options, :type), Keyword.fetch!(options, :process)),
      heartbeats?: Keyword.fetch!(options, :heartbeats?),
      status_error: &status_error(operation, &1, &2)
    )
  end

  # Items of the v1 API carry their content as payload, and none ends a
  # stream.
  defp decoder(expected_type, process) do
    fn
      %{"type" => ^expected_type, "payload" => payload}, line ->
        {:item, process.(payload, line)}

      %{"type" => "error"} = item, _line ->
        {:error, item_error(item["payload"])}

      %{"type" => "heartbeat"}, _line ->
        :skip

      %{"type" => type}, _line ->
        {:error, %InvalidResponseType{expected: expected_type, actual: type}}
    end
  end

  defp subject_body(subject, nil), do: %{subject: subject}
  defp subject_body(subject, options), do: %{subject: subject, options: options}

  # The event keeps the text of its data as it arrived, for verifying its hash.
  defp event(payload, line) do
    Event.new(payload, line |> RawJSON.member("payload") |> RawJSON.member("data"))
  end

  # The v1 API names the type eventType, and tells whether the type has no
  # events but only a schema as isPhantom.
  defp event_type(payload) do
    %EventType{
      type: payload["eventType"],
      has_events: not payload["isPhantom"],
      schema: payload["schema"]
    }
  end
end
