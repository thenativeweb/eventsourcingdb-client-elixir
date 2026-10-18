defmodule EventSourcingDBTest.FakeServer do
  @moduledoc false

  # A local HTTP/1 server that stands in for EventSourcingDB in tests that send
  # several requests, or that need control over each answer. It accepts every
  # connection, keeps it alive, and answers each request on it with what the
  # handler returns for the request, a map of :method, :path, and :body:
  #
  #   * {status, body} or {status, headers, body} - an answer, whose headers
  #     the Server header of EventSourcingDB precedes, unless they name one
  #   * {:lines, items} - an answer with status 200, whose body holds each item
  #     as a line of NDJSON
  #   * :close - closes the connection without an answer
  #   * :silent - never answers
  #
  # Every request is sent to the process that started the server as
  # {:fake_server, :request, request}.

  alias EventSourcingDB.Client
  alias EventSourcingDB.Transport.ApiVersion

  @spec start((map() -> term())) :: String.t()
  def start(handler) do
    owner = self()
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    ExUnit.Callbacks.start_supervised!(
      {Task, fn -> accept(listen_socket, owner, handler) end},
      id: make_ref()
    )

    # Neither the API that a server on the same port left behind before, nor
    # the API that the client SDK finds for this one, may outlive the server.
    url = "http://127.0.0.1:#{port}"
    client = Client.new(url, "secret")
    :ok = ApiVersion.forget(client)
    ExUnit.Callbacks.on_exit(fn -> ApiVersion.forget(client) end)
    url
  end

  defp accept(listen_socket, owner, handler) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    connection = spawn_link(fn -> serve(owner, handler) end)
    :ok = :gen_tcp.controlling_process(socket, connection)
    send(connection, {:socket, socket})
    accept(listen_socket, owner, handler)
  end

  defp serve(owner, handler) do
    receive do
      {:socket, socket} -> serve(socket, owner, handler, "")
    end
  end

  defp serve(socket, owner, handler, received) do
    case receive_request(socket, received) do
      {:ok, request, rest} ->
        send(owner, {:fake_server, :request, request})

        case answer(socket, handler.(request)) do
          :ok -> serve(socket, owner, handler, rest)
          :closed -> :ok
        end

      :closed ->
        :ok
    end
  end

  defp answer(socket, {:lines, items}) do
    body = Enum.map_join(items, &(Jason.encode!(&1) <> "\n"))
    answer(socket, {200, [{"content-type", "application/x-ndjson"}], body})
  end

  defp answer(socket, {status, body}), do: answer(socket, {status, [], body})

  defp answer(socket, {status, headers, body}) when is_integer(status) do
    headers =
      if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "server" end),
        do: headers,
        else: [{"server", "EventSourcingDB/test"} | headers]

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} \r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "content-length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ])

    :ok
  end

  defp answer(socket, :close) do
    :gen_tcp.close(socket)
    :closed
  end

  defp answer(socket, :silent) do
    # Keeps the connection open until the client closes it.
    _result = :gen_tcp.recv(socket, 0)
    :closed
  end

  defp receive_request(socket, received) do
    case String.split(received, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, path, _version] = String.split(request_line, " ")
        length = content_length(header_lines)

        with {:ok, rest} <- receive_at_least(socket, rest, length) do
          <<body::binary-size(length), rest::binary>> = rest
          {:ok, %{method: method, path: path, body: body}, rest}
        end

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0) do
          {:ok, data} -> receive_request(socket, received <> data)
          {:error, _reason} -> :closed
        end
    end
  end

  defp receive_at_least(_socket, data, length) when byte_size(data) >= length, do: {:ok, data}

  defp receive_at_least(socket, data, length) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, more} -> receive_at_least(socket, data <> more, length)
      {:error, _reason} -> :closed
    end
  end

  defp content_length(header_lines) do
    Enum.find_value(header_lines, 0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> content_length(String.downcase(name), value)
        _other -> nil
      end
    end)
  end

  defp content_length("content-length", value), do: value |> String.trim() |> String.to_integer()
  defp content_length(_name, _value), do: nil
end
