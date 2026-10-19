defmodule EventSourcingDB.Transport.V2 do
  @moduledoc false

  # The v2 API, which servers offer since EventSourcingDB 1.3.
  #
  # Every answer is an envelope of a type and its data, a single one or a
  # stream of NDJSON lines. Every stream sends heartbeats, and every stream
  # but observing events ends with an end item, which it must not leave out.
  # Writes answer with a stream as well, so that a long write keeps the
  # connection alive. Reads use the method QUERY. The API refuses unknown
  # fields and JSON null, so optional fields are left out rather than sent as
  # null.

  @behaviour EventSourcingDB.Transport.API

  alias EventSourcingDB.{Event, EventCandidate, EventType, ManagementEvent, RawJSON}

  alias EventSourcingDB.Errors.{
    DbApiError,
    InvalidEventType,
    InvalidResponseType,
    PingFailed,
    TransmissionError
  }

  alias EventSourcingDB.Transport.{ApiVersion, HTTP, WriteOutcome}

  #
  # region Requests with a single answer
  #

  # A ping carries no API token, since EventSourcingDB answers it without one.
  @impl true
  def ping(client) do
    with {:ok, envelope} <- request(client, :get, "/api/v2/system/ping", nil, authorize: false) do
      case envelope do
        %{"type" => "event", "data" => %{"type" => "io.eventsourcingdb.api.ping-received"}} -> :ok
        _other -> {:error, %PingFailed{}}
      end
    end
  end

  @impl true
  def verify_api_token(client) do
    with {:ok, envelope} <- request(client, :post, "/api/v2/system/verify-token", nil) do
      case envelope do
        %{"type" => "event", "data" => %{"type" => "io.eventsourcingdb.api.token-verified"}} ->
          :ok

        _other ->
          {:error, %InvalidEventType{}}
      end
    end
  end

  @impl true
  def read_event_type(client, event_type) do
    with {:ok, envelope} <-
           request(client, :query, "/api/v2/data/read-event-type", %{type: event_type}) do
      case envelope do
        %{"type" => "eventType", "data" => data} -> {:ok, EventType.new(data)}
        %{"type" => type} -> {:error, %InvalidResponseType{expected: "eventType", actual: type}}
      end
    end
  end

  # A single answer is an envelope, which may hold an error that the server
  # reports at status 200, while another status carries the text of an error.
  defp request(client, method, path, body, options \\ []) do
    case HTTP.one_shot(client, method, path, body, options) do
      {:ok, %Req.Response{status: 200, body: text}} ->
        envelope(text)

      {:ok, %Req.Response{body: text} = response} ->
        {:error, status_error(client, response, text)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A server that answers a route of the v2 API with 404 or 405 no longer
  # offers it, for example because it was rolled back to a version without
  # it, so the API is forgotten, and the next request asks again.
  defp status_error(client, %Req.Response{status: status} = response, text) do
    if status in [404, 405], do: ApiVersion.forget(client)
    DbApiError.from_response(response, text)
  end

  defp envelope(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "error", "data" => data}} -> {:error, DbApiError.from_item(data, 200)}
      {:ok, %{"type" => type} = envelope} when is_binary(type) -> {:ok, envelope}
      {:ok, _other} -> {:error, %InvalidResponseType{expected: "an envelope", actual: text}}
      {:error, reason} -> {:error, %TransmissionError{reason: reason}}
    end
  end

  #
  # region Writes
  #

  @impl true
  def write_events(client, events, preconditions) do
    body = %{events: Enum.map(events, &candidate/1), preconditions: preconditions}

    client
    |> HTTP.stream(:post, "/api/v2/data/write-events", body,
      decode: decoder("event", &event/2),
      heartbeats?: true,
      ending: :end_item,
      track_sending: true,
      status_error: &status_error(client, &1, &2)
    )
    |> collect()
    |> WriteOutcome.classify(:v2)
  end

  # An event candidate leaves out its optional fields, which a map given in
  # its place may hold as nil.
  defp candidate(%EventCandidate{} = candidate), do: candidate

  defp candidate(candidate) when is_map(candidate) and not is_struct(candidate),
    do: Map.reject(candidate, fn {_key, value} -> is_nil(value) end)

  defp candidate(candidate), do: candidate

  @impl true
  def register_event_schema(client, event_type, schema) do
    client
    |> HTTP.stream(
      :post,
      "/api/v2/data/register-event-schema",
      %{type: event_type, schema: schema},
      decode: decoder("event", fn data, _line -> schema_registered(data) end),
      heartbeats?: true,
      ending: :end_item,
      track_sending: true,
      status_error: &status_error(client, &1, &2)
    )
    |> collect()
    |> then(fn
      {:ok, [%ManagementEvent{} = event]} -> {:ok, event}
      {:ok, _events} -> {:error, %InvalidResponseType{expected: "event", actual: "end"}}
      error -> error
    end)
    |> WriteOutcome.classify(:v2)
  end

  defp schema_registered(%{"type" => "io.eventsourcingdb.api.event-schema-registered"} = data),
    do: ManagementEvent.new(data)

  defp schema_registered(_data), do: raise(%InvalidEventType{})

  # Reads the stream of a write to its end, and returns what it raises.
  defp collect({:ok, stream}) do
    {:ok, Enum.to_list(stream)}
  rescue
    error -> {:error, error}
  end

  defp collect({:error, reason}), do: {:error, reason}

  #
  # region Streams
  #

  @impl true
  def read_events(client, subject, options) do
    stream(client, "/api/v2/data/read-events", subject_body(subject, options),
      type: "event",
      process: &event/2
    )
  end

  # Observing events never ends, so the server sends no end item.
  @impl true
  def observe_events(client, subject, options) do
    stream(client, "/api/v2/data/observe-events", subject_body(subject, options),
      type: "event",
      process: &event/2,
      ending: :never
    )
  end

  # Each row holds the value that the query projects.
  @impl true
  def run_eventql_query(client, query) do
    stream(client, "/api/v2/data/run-eventql-query", %{query: query},
      type: "row",
      process: fn data, _line -> data["value"] end
    )
  end

  @impl true
  def read_subjects(client, subject, recursive) do
    stream(
      client,
      "/api/v2/data/read-subjects",
      %{subject: subject, options: %{recursive: recursive}},
      type: "subject",
      process: fn data, _line -> data["subject"] end
    )
  end

  @impl true
  def read_event_types(client) do
    stream(client, "/api/v2/data/read-event-types", nil,
      type: "eventType",
      process: fn data, _line -> EventType.new(data) end
    )
  end

  defp stream(client, path, body, options) do
    HTTP.stream(client, :query, path, body,
      status_error: &status_error(client, &1, &2),
      decode: decoder(Keyword.fetch!(options, :type), Keyword.fetch!(options, :process)),
      heartbeats?: true,
      ending: Keyword.get(options, :ending, :end_item)
    )
  end

  # Items of the v2 API carry their content as data.
  defp decoder(expected_type, process) do
    fn
      %{"type" => ^expected_type, "data" => data}, line ->
        {:item, process.(data, line)}

      %{"type" => "error", "data" => data}, _line ->
        {:error, DbApiError.from_item(data, 200)}

      %{"type" => "heartbeat"}, _line ->
        :skip

      %{"type" => "end"}, _line ->
        :end

      %{"type" => type}, _line ->
        {:error, %InvalidResponseType{expected: expected_type, actual: type}}
    end
  end

  defp subject_body(subject, nil), do: %{subject: subject}
  defp subject_body(subject, options), do: %{subject: subject, options: options}

  # The event keeps the text of its data as it arrived, for verifying its hash.
  defp event(data, line) do
    Event.new(data, line |> RawJSON.member("data") |> RawJSON.member("data"))
  end
end
