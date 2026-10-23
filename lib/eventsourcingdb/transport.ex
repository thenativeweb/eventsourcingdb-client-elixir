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
  # asks again. For a call with a timeout, the deadline of the call bounds
  # asking as well. A write with a precondition that only the v2 API checks
  # asks again if the remembered answer is the v1 API.

  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.{DbApiError, InvalidResponseType, PingFailed, TransmissionError}
  alias EventSourcingDB.Transport.{ApiVersion, Deadline, HTTP, V1, V2}

  @probe_path "/api/v2/system/ping"

  @spec api(Client.t(), atom(), Deadline.t() | nil) :: {:ok, module()} | {:error, Exception.t()}
  def api(%Client{} = client, call \\ :other, deadline \\ nil) do
    probe = fn -> probe(client, call, deadline) end

    case ApiVersion.resolve(client, probe, share: deadline == nil, stale: stale(call)) do
      {:ok, :v1} -> {:ok, V1}
      {:ok, :v2} -> {:ok, V2}
      {:error, reason} -> {:error, reason}
    end
  end

  # A write with a precondition that only the v2 API checks asks the server
  # again whether it offers the v2 API, if the client remembered that it does
  # not, since the server may have been upgraded since, rather than fail for
  # the lack of it. Every other call keeps using the remembered API.
  defp stale(:write_events_needing_v2), do: :v1
  defp stale(_call), do: nil

  # Every request makes a single attempt, unless the client has Req retry
  # through its req_options. Even then, the probe is retried only before a
  # ping, as the ping itself would be, since both are GET requests, and makes
  # a single attempt before every other call.
  #
  # Like the ping, the probe carries no API token, since EventSourcingDB
  # answers the v2 ping without one.
  #
  # A 404 or 405 means the v1 API even if it does not come from
  # EventSourcingDB, such as from a proxy that forwards only the v1 API, since
  # every request of the v1 API checks that its answer does. Every other answer
  # must come from EventSourcingDB.
  defp probe(client, call, deadline) do
    options = if call == :ping, do: [], else: [retry: false]
    options = [authorize: false, deadline: deadline] ++ options

    case HTTP.unchecked_one_shot(client, :get, @probe_path, nil, options) do
      {:ok, %Req.Response{status: status}} when status in [404, 405] ->
        {:ok, :v1}

      {:ok, response} ->
        with :ok <- HTTP.validate_server_header(response), do: probe_answer(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_answer(%Req.Response{status: 200, body: body}), do: v2_ping(body)

  defp probe_answer(%Req.Response{body: text} = response),
    do: {:error, DbApiError.from_response(response, text)}

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
