defmodule EventSourcingDB.Transport.V1 do
  @moduledoc false

  # The v1 API, which servers offer up to EventSourcingDB 1.2.

  @behaviour EventSourcingDB.Transport.API

  alias EventSourcingDB.{Event, EventType, ManagementEvent, RawJSON}

  alias EventSourcingDB.Errors.{
    ApiError,
    ApiTokenInvalid,
    DBError,
    InvalidEventType,
    InvalidResponseType,
    PingFailed,
    TransmissionError
  }

  alias EventSourcingDB.Transport.HTTP

  #
  # region Requests with a single answer
  #

  @impl true
  def ping(client) do
    with {:ok, body} <- request(client, :get, "/api/v1/ping", nil) do
      case body do
        %{"type" => "io.eventsourcingdb.api.ping-received"} -> :ok
        _other -> {:error, %PingFailed{}}
      end
    end
  end

  @impl true
  def verify_api_token(client) do
    case HTTP.one_shot(client, :post, "/api/v1/verify-api-token", %{}) do
      {:ok, %Req.Response{status: 401}} ->
        {:error, %ApiTokenInvalid{}}

      result ->
        with {:ok, body} <- json_body(result), do: token_verified(body)
    end
  end

  defp token_verified(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: :ok
  defp token_verified(_body), do: {:error, %InvalidEventType{}}

  @impl true
  def write_events(client, events, preconditions) do
    body = %{events: events, preconditions: preconditions}

    with {:ok, text} <- text_body(HTTP.one_shot(client, :post, "/api/v1/write-events", body)) do
      written_events(text)
    end
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

    with {:ok, body} <- request(client, :post, "/api/v1/register-event-schema", body) do
      case body do
        %{"type" => "io.eventsourcingdb.api.event-schema-registered"} ->
          {:ok, ManagementEvent.new(body)}

        _other ->
          {:error, %InvalidEventType{}}
      end
    end
  end

  @impl true
  def read_event_type(client, event_type) do
    with {:ok, body} <-
           request(client, :post, "/api/v1/read-event-type", %{eventType: event_type}) do
      {:ok, event_type(body)}
    end
  end

  defp request(client, method, path, body) do
    json_body(HTTP.one_shot(client, method, path, body))
  end

  defp json_body(result) do
    with {:ok, text} <- text_body(result) do
      case Jason.decode(text) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, %TransmissionError{reason: reason}}
      end
    end
  end

  defp text_body({:ok, %Req.Response{status: 200, body: text}}), do: {:ok, text}
  defp text_body({:ok, %Req.Response{body: text}}), do: {:error, %ApiError{reason: text}}
  defp text_body({:error, reason}), do: {:error, reason}

  #
  # region Streams
  #

  @impl true
  def read_events(client, subject, options) do
    stream(client, "/api/v1/read-events", subject_body(subject, options), "event", &event/2,
      heartbeats?: false
    )
  end

  @impl true
  def observe_events(client, subject, options) do
    # The server sends a heartbeat every second while there is nothing else to
    # send.
    stream(client, "/api/v1/observe-events", subject_body(subject, options), "event", &event/2,
      heartbeats?: true
    )
  end

  @impl true
  def run_eventql_query(client, query) do
    # The server sends a heartbeat every second while there is nothing else to
    # send.
    stream(client, "/api/v1/run-eventql-query", %{query: query}, "row", fn row, _line -> row end,
      heartbeats?: true
    )
  end

  @impl true
  def read_subjects(client, subject, _recursive) do
    stream(
      client,
      "/api/v1/read-subjects",
      %{baseSubject: subject},
      "subject",
      fn payload, _line -> payload["subject"] end,
      heartbeats?: false
    )
  end

  @impl true
  def read_event_types(client) do
    stream(
      client,
      "/api/v1/read-event-types",
      %{},
      "eventType",
      fn payload, _line ->
        event_type(payload)
      end,
      heartbeats?: false
    )
  end

  defp stream(client, path, body, type, process, options) do
    HTTP.stream(client, :post, path, body, [decode: decoder(type, process)] ++ options)
  end

  # Items of the v1 API carry their content as payload, and none ends a
  # stream.
  defp decoder(expected_type, process) do
    fn
      %{"type" => ^expected_type, "payload" => payload}, line ->
        {:item, process.(payload, line)}

      %{"type" => "error", "payload" => payload}, _line ->
        {:error, %DBError{payload: payload}}

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

  defp event_type(payload), do: EventType.new(payload)
end
