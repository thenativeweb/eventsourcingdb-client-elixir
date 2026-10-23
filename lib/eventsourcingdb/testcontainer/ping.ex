defmodule EventSourcingDB.TestContainer.Ping do
  @moduledoc false

  # Asks the database in a container once whether it is ready, as both waits
  # for a container do, TestContainer.start/1 and the wait with which
  # Testcontainers starts the container itself.
  #
  # It asks for the ping of the v2 API, without a token, and for the ping of
  # the v1 API only if the server answers that with 404 or 405, as a server
  # without the v2 API does. So it works with servers with and without
  # either API. The database is ready once either ping is answered with
  # 200 OK. Anything else fails the attempt, such as a refused connection, a
  # request that runs out of time, or another status, such as 503, and the
  # next attempt starts with the ping of the v2 API again, as a server that
  # is starting may answer anything.

  @v2_ping "api/v2/system/ping"
  @v1_ping "api/v1/ping"
  @statuses_without_v2_api [404, 405]

  # Req starts a pool of connections of its own for each set of connect
  # options, which stays, so the pings always connect with the same options,
  # and only the time they wait for an answer varies.
  @connect_options [timeout: 1_000]

  @doc false
  @spec answers?(String.t(), integer(), timeout()) :: boolean()
  def answers?(base_url, deadline, request_timeout) do
    case get(base_url <> @v2_ping, deadline, request_timeout) do
      {:ok, 200} ->
        true

      {:ok, status} when status in @statuses_without_v2_api ->
        get(base_url <> @v1_ping, deadline, request_timeout) == {:ok, 200}

      _not_ready ->
        false
    end
  end

  # Waits for an answer for the request timeout, and never past the
  # deadline.
  defp get(url, deadline, request_timeout) do
    timeout = min(request_timeout, deadline - System.monotonic_time(:millisecond))

    if timeout > 0 do
      response =
        Req.get(url,
          retry: false,
          redirect: false,
          decode_body: false,
          connect_options: @connect_options,
          receive_timeout: timeout
        )

      case response do
        {:ok, %Req.Response{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :timeout}
    end
  end
end
