defmodule EventSourcingDBTest.StreamServer do
  @moduledoc false
  alias EventSourcingDB.Client

  # A local HTTP server that stands in for EventSourcingDB in tests that need
  # control over the timing of a stream. It accepts a single request and hands
  # the connection to the given script, which sends the response head and the
  # NDJSON lines. Afterwards it keeps the connection open without sending
  # anything else, and sends {:stream_server, :closed} to the process that
  # started it once the client closes the connection.

  @response_head [
    "HTTP/1.1 200 OK\r\n",
    "Server: EventSourcingDB/test\r\n",
    "Content-Type: application/x-ndjson\r\n",
    "Transfer-Encoding: chunked\r\n",
    "\r\n"
  ]

  @spec start((:gen_tcp.socket() -> any())) :: Client.t()
  def start(script) do
    owner = self()

    ExUnit.Callbacks.start_supervised!({Task, fn -> serve(owner, script) end})

    receive do
      {:stream_server, :listening, port} ->
        Client.new(
          base_url: "http://127.0.0.1:#{port}",
          api_token: "secret",
          req_options: [retry: false]
        )
    after
      1_000 -> raise "Stream server did not start."
    end
  end

  @spec send_head(:gen_tcp.socket()) :: :ok | {:error, any()}
  def send_head(socket) do
    :gen_tcp.send(socket, @response_head)
  end

  @spec send_line(:gen_tcp.socket(), map()) :: :ok | {:error, any()}
  def send_line(socket, line) do
    data = Jason.encode!(line) <> "\n"

    :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
  end

  defp serve(owner, script) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    send(owner, {:stream_server, :listening, port})

    {:ok, socket} = :gen_tcp.accept(listen_socket)
    :ok = receive_request_head(socket, "")

    script.(socket)

    wait_for_close(socket)
    send(owner, {:stream_server, :closed})
  end

  defp receive_request_head(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :gen_tcp.recv(socket, 0)
      receive_request_head(socket, received <> data)
    end
  end

  defp wait_for_close(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _data} -> wait_for_close(socket)
      {:error, _reason} -> :ok
    end
  end
end
