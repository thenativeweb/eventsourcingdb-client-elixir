defmodule EventSourcingDBTest.StreamServer do
  @moduledoc false
  alias EventSourcingDB.Client

  # A local HTTP server that stands in for EventSourcingDB in tests that need
  # control over the timing of a stream. It accepts a single request and hands
  # the connection to the given script, which sends the response head and the
  # NDJSON lines. Afterwards it keeps the connection open without sending
  # anything else, and sends {:stream_server, :closed} to the process that
  # started it once the client closes the connection.
  #
  # With the protocol option set to :http2, it speaks HTTP/2 without TLS (h2c
  # with prior knowledge), and the client uses an HTTP/2 pool. There the
  # client ends a stream by resetting it and keeps the connection, so a reset
  # counts as closing.

  @response_headers [
    {"server", "EventSourcingDB/test"},
    {"content-type", "application/x-ndjson"}
  ]

  @http2_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  # HTTP/2 frame types and flags, see RFC 9113.
  @data_frame 0x0
  @headers_frame 0x1
  @rst_stream_frame 0x3
  @settings_frame 0x4
  @goaway_frame 0x7
  @end_stream_flag 0x1
  @ack_flag 0x1
  @end_headers_flag 0x4

  # The status 200 is entry 8 of the static HPACK table.
  @status_200 0x88

  @guard_timeout 5_000

  @type connection() :: :gen_tcp.socket() | {:http2, :gen_tcp.socket(), pos_integer()}

  @spec start((connection() -> any()), keyword()) :: Client.t()
  def start(script, options \\ []) do
    owner = self()
    protocol = Keyword.get(options, :protocol, :http1)
    req_options = [retry: false] ++ Keyword.get(options, :req_options, req_options(protocol))

    ExUnit.Callbacks.start_supervised!({Task, fn -> serve(owner, script, protocol) end})

    receive do
      {:stream_server, :listening, port} ->
        base_url = "http://127.0.0.1:#{port}"

        if protocol == :http2 do
          ExUnit.Callbacks.on_exit(fn -> stop_pool(req_options, base_url) end)
          warm_up(req_options, base_url)
        end

        Client.new(base_url: base_url, api_token: "secret", req_options: req_options)
    after
      1_000 -> raise "Stream server did not start."
    end
  end

  @spec send_head(connection()) :: :ok | {:error, any()}
  def send_head(connection) do
    send_head(connection, 200, @response_headers)
  end

  # Sends the head of a response with the given status and header fields,
  # whose body follows through send_data/2 and send_end/1.
  @spec send_head(connection(), pos_integer(), [{String.t(), String.t()}]) ::
          :ok | {:error, any()}
  def send_head({:http2, socket, stream_id}, status, headers) do
    # The header fields are literals without indexing and without Huffman
    # coding.
    header_block = [
      status_field(status) | Enum.map(headers, fn {name, value} -> header_field(name, value) end)
    ]

    send_frame(socket, @headers_frame, @end_headers_flag, stream_id, header_block)
  end

  def send_head(socket, status, headers) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} \r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "transfer-encoding: chunked\r\n",
      "\r\n"
    ])
  end

  @spec send_line(connection(), map()) :: :ok | {:error, any()}
  def send_line(connection, line) do
    send_data(connection, Jason.encode!(line) <> "\n")
  end

  @spec send_data(connection(), binary()) :: :ok | {:error, any()}
  def send_data({:http2, socket, stream_id}, data) do
    send_frame(socket, @data_frame, 0, stream_id, data)
  end

  def send_data(socket, data) do
    :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
  end

  # Ends the response the way EventSourcingDB does, which over HTTP/2 is an
  # empty data frame.
  @spec send_end(connection()) :: :ok | {:error, any()}
  def send_end({:http2, socket, stream_id}) do
    send_frame(socket, @data_frame, @end_stream_flag, stream_id, "")
  end

  def send_end(socket) do
    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  # Runs the given function in a separate process, which opens and reads the
  # stream, and fails the test if it does not return in time, so a stream that
  # never ends can not hang the test suite.
  @spec run_with_guard((-> any())) :: {{:ok, any()} | {:raised, Exception.t()}, integer()}
  def run_with_guard(fun) do
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          exception -> {:raised, exception}
        end
      end)

    case Task.yield(task, @guard_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {result, System.monotonic_time(:millisecond) - started_at}
      _ -> ExUnit.Assertions.flunk("Stream did not end within #{@guard_timeout} ms.")
    end
  end

  defp req_options(:http1), do: []
  defp req_options(:http2), do: [connect_options: [protocols: [:http2]]]

  # Finch registers an HTTP/2 pool only once it has connected, and fails a
  # request with :pool_not_available until then, which is likely for the first
  # request to a new pool. So a first request, which the server answers by
  # itself, retries until the pool is ready, and the client then finds it so.
  defp warm_up(req_options, base_url) do
    retry = fn _request, response_or_exception ->
      case response_or_exception do
        %Req.HTTPError{reason: :pool_not_available} -> {:delay, 10}
        _ -> false
      end
    end

    {:ok, %Req.Response{status: 200}} =
      req_options
      |> Keyword.merge(url: base_url, retry: retry, max_retries: 100, retry_log_level: false)
      |> Req.request()
  end

  # Req starts a Finch pool for connection options of their own. An HTTP/2
  # pool reconnects once the server is gone, and logs a warning whenever that
  # fails, so the pool is stopped after the test.
  defp stop_pool(req_options, base_url) do
    if Keyword.has_key?(req_options, :connect_options) do
      req_options
      |> Req.Finch.pool_options()
      |> Req.Finch.pool_name()
      |> Finch.stop_pool(base_url)
    end
  end

  defp serve(owner, script, protocol) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    send(owner, {:stream_server, :listening, port})

    {:ok, socket} = :gen_tcp.accept(listen_socket)
    connection = receive_request(socket, protocol)

    script.(connection)

    wait_for_close(connection)
    send(owner, {:stream_server, :closed})
  end

  defp receive_request(socket, :http1) do
    :ok = receive_request_head(socket, "")
    socket
  end

  defp receive_request(socket, :http2) do
    {:ok, @http2_preface} = :gen_tcp.recv(socket, byte_size(@http2_preface))
    :ok = send_frame(socket, @settings_frame, 0, 0, "")

    # The first request is the warm-up, see warm_up/2.
    warm_up_stream_id = receive_http2_request(socket)
    flags = Bitwise.bor(@end_headers_flag, @end_stream_flag)
    :ok = send_frame(socket, @headers_frame, flags, warm_up_stream_id, [@status_200])

    {:http2, socket, receive_http2_request(socket)}
  end

  defp receive_request_head(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :gen_tcp.recv(socket, 0)
      receive_request_head(socket, received <> data)
    end
  end

  # Reads frames until the client has sent a whole request, acknowledges the
  # settings of the client on the way, and returns the stream of the request.
  defp receive_http2_request(socket) do
    {:ok, type, flags, stream_id, _payload} = receive_frame(socket)

    cond do
      type in [@headers_frame, @data_frame] and flag?(flags, @end_stream_flag) ->
        stream_id

      type == @settings_frame and not flag?(flags, @ack_flag) ->
        :ok = send_frame(socket, @settings_frame, @ack_flag, 0, "")
        receive_http2_request(socket)

      true ->
        receive_http2_request(socket)
    end
  end

  defp wait_for_close({:http2, socket, stream_id} = connection) do
    case receive_frame(socket) do
      {:ok, @rst_stream_frame, _flags, ^stream_id, _payload} -> :ok
      {:ok, @goaway_frame, _flags, _stream_id, _payload} -> :ok
      {:ok, _type, _flags, _stream_id, _payload} -> wait_for_close(connection)
      {:error, _reason} -> :ok
    end
  end

  defp wait_for_close(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _data} -> wait_for_close(socket)
      {:error, _reason} -> :ok
    end
  end

  defp receive_frame(socket) do
    with {:ok, <<length::24, type::8, flags::8, _reserved::1, stream_id::31>>} <-
           :gen_tcp.recv(socket, 9),
         {:ok, payload} <- receive_payload(socket, length) do
      {:ok, type, flags, stream_id, payload}
    end
  end

  defp receive_payload(_socket, 0), do: {:ok, ""}
  defp receive_payload(socket, length), do: :gen_tcp.recv(socket, length)

  defp send_frame(socket, type, flags, stream_id, payload) do
    length = IO.iodata_length(payload)

    :gen_tcp.send(socket, [<<length::24, type::8, flags::8, 0::1, stream_id::31>>, payload])
  end

  # The status takes the name of entry 8 of the static HPACK table.
  defp status_field(status) do
    value = Integer.to_string(status)
    [0x08, byte_size(value), value]
  end

  defp header_field(name, value) do
    [0x00, byte_size(name), name, byte_size(value), value]
  end

  defp flag?(flags, flag), do: Bitwise.band(flags, flag) != 0
end
