defmodule EventSourcingDB.Transport do
  @moduledoc false

  # The one place that chooses the API through which the client talks to the
  # server. Every call of the client SDK asks for the API here, and then runs
  # on the module that implements EventSourcingDB.Transport.API for it.
  #
  # On the first request of a client, the client asks the server for the v2
  # ping. EventSourcingDB answers it with a ping-received event if it offers
  # the v2 API, and with 404 or 405 if it does not, as EventSourcingDB 1.2
  # does, with or without its UI. The answer is remembered for the client.
  # Anything else, such as a failed connection or a 5xx, fails the request
  # with that error, and leaves the API unknown, so that the next request
  # asks again.

  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.{DbApiError, InvalidResponseType, PingFailed, TransmissionError}
  alias EventSourcingDB.Transport.{ApiVersion, HTTP, V1, V2}

  @probe_path "/api/v2/system/ping"

  @spec api(Client.t(), atom()) :: {:ok, module()} | {:error, Exception.t()}
  def api(%Client{} = client, call \\ :other) do
    case ApiVersion.resolve(client, fn -> probe(client, call) end) do
      {:ok, :v1} -> {:ok, V1}
      {:ok, :v2} -> {:ok, V2}
      {:error, reason} -> {:error, reason}
    end
  end

  # Req retries a GET request after a transient error, as the probe is. Only a
  # ping is a GET request among the calls of the client SDK, so the probe is
  # retried only before a ping, as the ping would be, and makes a single
  # attempt before every other call, which Req never retries.
  defp probe(client, call) do
    options = if call == :ping, do: [], else: [retry: false]

    case HTTP.one_shot(client, :get, @probe_path, nil, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        v2_ping(body)

      {:ok, %Req.Response{status: status}} when status in [404, 405] ->
        {:ok, :v1}

      {:ok, %Req.Response{body: text} = response} ->
        {:error, DbApiError.from_response(response, text)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp v2_ping(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "event", "data" => %{"type" => "io.eventsourcingdb.api.ping-received"}}} ->
        {:ok, :v2}

      {:ok, %{"type" => "event"}} ->
        {:error, %PingFailed{}}

      {:ok, %{"type" => "error", "data" => data}} ->
        {:error, DbApiError.from_item(data, 200)}

      {:ok, %{"type" => type}} ->
        {:error, %InvalidResponseType{expected: "event", actual: type}}

      {:ok, _other} ->
        {:error, %InvalidResponseType{expected: "event", actual: body}}

      {:error, reason} ->
        {:error, %TransmissionError{reason: reason}}
    end
  end
end
