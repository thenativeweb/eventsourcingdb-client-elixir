defmodule EventSourcingDBTest.HTTP2 do
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.Errors.DBError
  alias EventSourcingDB.Errors.HeartbeatTimeout
  alias EventSourcingDB.Errors.InvalidServerHeader
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.Event
  alias EventSourcingDBTest.StreamServer

  # The heartbeat timeout is shortened through the application environment,
  # which is global, so these tests must not run concurrently with others.
  use ExUnit.Case, async: false

  @heartbeat_timeout 500
  @heartbeat_interval 100

  # Streams with heartbeats wait twice the heartbeat timeout for the response
  # headers, which is the receive timeout over HTTP/1.
  @receive_timeout 2 * @heartbeat_timeout

  # Streams without heartbeats use the receive timeout of the client, which
  # these tests shorten as well.
  @client_receive_timeout 300
  @client_req_options [
    connect_options: [protocols: [:http2]],
    receive_timeout: @client_receive_timeout
  ]

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}

  setup do
    Application.put_env(:eventsourcingdb, :heartbeat_timeout, @heartbeat_timeout)
    on_exit(fn -> Application.delete_env(:eventsourcingdb, :heartbeat_timeout) end)
  end

  test "keeps observing events over HTTP/2 while heartbeats arrive" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          send_heartbeats(connection, 2 * @receive_timeout)
          StreamServer.send_line(connection, event_line("0"))
        end,
        protocol: :http2
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [Event.new(event_payload("0"))]}
    assert elapsed >= 2 * @receive_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps running an EventQL query over HTTP/2 while heartbeats arrive" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          send_heartbeats(connection, 2 * @receive_timeout)
          StreamServer.send_line(connection, row_line(1))
        end,
        protocol: :http2
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(1)
      end)

    assert result == {:ok, [1]}
    assert elapsed >= 2 * @receive_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps reading events over HTTP/2 while they arrive" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)

          for id <- 0..9 do
            StreamServer.send_line(connection, event_line(Integer.to_string(id)))
            Process.sleep(@heartbeat_interval)
          end
        end,
        protocol: :http2,
        req_options: @client_req_options
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(10)
      end)

    assert result == {:ok, Enum.map(0..9, &Event.new(event_payload(Integer.to_string(&1))))}
    assert elapsed >= 3 * @client_receive_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "reads events over HTTP/2 up to the end of the response" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_line(connection, event_line("0"))
          StreamServer.send_line(connection, event_line("1"))
          StreamServer.send_end(connection)
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "reads an event over HTTP/2 whose line arrives in several data frames" do
    line = Jason.encode!(event_line("0")) <> "\n"

    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_data(connection, binary_part(line, 0, 100))
          StreamServer.send_data(connection, binary_part(line, 100, byte_size(line) - 100))
          StreamServer.send_end(connection)
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:ok, [Event.new(event_payload("0"))]}
  end

  test "ends observing events over HTTP/2 with a heartbeat timeout if nothing arrives" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_line(connection, @heartbeat)
        end,
        protocol: :http2
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %HeartbeatTimeout{}}, result)
    assert elapsed >= @heartbeat_timeout
    assert elapsed < 2 * @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends reading events over HTTP/2 with a transmission error if nothing arrives" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_line(connection, event_line("0"))
        end,
        protocol: :http2,
        req_options: @client_req_options
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %TransmissionError{}}, result)
    assert elapsed >= @client_receive_timeout
    assert elapsed < 2 * @client_receive_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "fails to observe events over HTTP/2 if the response does not arrive" do
    client = StreamServer.start(fn _connection -> :ok end, protocol: :http2)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events(client, "/test")
      end)

    assert match?({:ok, {:error, %TransmissionError{}}}, result)
    assert elapsed >= @receive_timeout
    assert elapsed < 2 * @receive_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises an error from the database that arrives over HTTP/2" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_line(connection, @heartbeat)

          StreamServer.send_line(connection, %{
            "type" => "error",
            "payload" => %{"error" => "something went wrong"}
          })
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:raised, %DBError{payload: %{"error" => "something went wrong"}}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "leaves the other messages of the process in its mailbox while observing events over HTTP/2" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection)
          StreamServer.send_line(connection, @heartbeat)
          StreamServer.send_line(connection, event_line("0"))
          Process.sleep(@heartbeat_interval)
          StreamServer.send_line(connection, @heartbeat)
          StreamServer.send_line(connection, event_line("1"))
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        send(self(), :before_reading)

        events =
          EventSourcingDB.observe_events!(client, "/test")
          |> Stream.each(fn event -> send(self(), {:while_reading, event.id}) end)
          |> Enum.take(2)

        {Enum.map(events, & &1.id), mailbox()}
      end)

    assert result ==
             {:ok, {["0", "1"], [:before_reading, {:while_reading, "0"}, {:while_reading, "1"}]}}

    assert_receive {:stream_server, :closed}, 1_000
  end

  test "fails to read events over HTTP/2 with the text of an error response, and leaves none of its messages behind" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection, 400, [
            {"server", "EventSourcingDB/test"},
            {"content-type", "text/plain; charset=utf-8"}
          ])

          StreamServer.send_data(connection, "malformed ")
          Process.sleep(@heartbeat_interval)
          StreamServer.send_data(connection, "subject\n")
          StreamServer.send_end(connection)
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        result = EventSourcingDB.read_events(client, "invalid")
        Process.sleep(2 * @heartbeat_interval)

        {result, mailbox()}
      end)

    assert result == {:ok, {{:error, %ApiError{reason: "malformed subject\n"}}, []}}
  end

  test "fails to observe events over HTTP/2 from a server that is not EventSourcingDB, and closes the stream" do
    client =
      StreamServer.start(
        fn connection ->
          StreamServer.send_head(connection, 200, [
            {"server", "SomethingElse/1.0"},
            {"content-type", "application/x-ndjson"}
          ])

          send_heartbeats(connection, 5 * @heartbeat_interval)
        end,
        protocol: :http2
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        result = EventSourcingDB.observe_events(client, "/test")
        Process.sleep(2 * @heartbeat_interval)

        {result, mailbox()}
      end)

    assert result == {:ok, {{:error, %InvalidServerHeader{}}, []}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  defp send_heartbeats(connection, duration) do
    for _ <- 1..div(duration, @heartbeat_interval) do
      StreamServer.send_line(connection, @heartbeat)
      Process.sleep(@heartbeat_interval)
    end
  end

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp event_line(id) do
    %{"type" => "event", "payload" => event_payload(id)}
  end

  defp event_payload(id) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "time" => "2026-10-03T12:00:00.000000000Z",
      "source" => "https://EventSourcingDB.io",
      "subject" => "/test",
      "type" => "io.eventsourcingdb.test",
      "datacontenttype" => "application/json",
      "data" => %{"value" => id},
      "hash" => String.duplicate("0", 64),
      "predecessorhash" => String.duplicate("0", 64)
    }
  end

  defp row_line(value) do
    %{"type" => "row", "payload" => value}
  end
end
