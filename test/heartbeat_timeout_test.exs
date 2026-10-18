defmodule EventSourcingDBTest.HeartbeatTimeout do
  alias EventSourcingDB.Errors.ConnectionStalled
  alias EventSourcingDB.Event
  alias EventSourcingDBTest.StreamServer

  # These tests measure how long a stream takes, so they do not run
  # concurrently with others.
  use ExUnit.Case, async: false

  @stall_timeout 500
  @heartbeat_interval 100

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}

  test "ends observing events as a stalled connection if nothing arrives" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %ConnectionStalled{}}, result)
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends running an EventQL query as a stalled connection if nothing arrives" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e")
        |> Enum.to_list()
      end)

    assert match?({:raised, %ConnectionStalled{}}, result)
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends observing events as a stalled connection even if other messages arrive" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        reader = self()

        spawn_link(fn ->
          for i <- 1..div(2 * @stall_timeout, @heartbeat_interval) do
            send(reader, {:unrelated, i})
            Process.sleep(@heartbeat_interval)
          end
        end)

        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %ConnectionStalled{}}, result)
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps observing events while parts of a line arrive" do
    line = Jason.encode!(event_line("0")) <> "\n"
    parts = 2 * div(@stall_timeout, @heartbeat_interval)

    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)

        # The line in parts, one after the other, which together take twice the
        # stall timeout, while each of them arrives well within it.
        send_parts(socket, line, parts)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [expected_event("0")]}
    assert elapsed >= 2 * @stall_timeout
  end

  test "ends observing events as a stalled connection once parts of a line stop arriving" do
    line = Jason.encode!(event_line("0")) <> "\n"
    parts = 2 * div(@stall_timeout, @heartbeat_interval)

    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)

        # All parts of the line but the last one, which take twice the stall
        # timeout, after which nothing arrives anymore.
        send_parts(socket, binary_part(line, 0, byte_size(line) - 1), parts)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %ConnectionStalled{}}, result)
    assert elapsed >= 3 * @stall_timeout
    assert elapsed < 4 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps observing events while heartbeats arrive" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        send_heartbeats(socket, 3 * @stall_timeout)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [expected_event("0")]}
    assert elapsed >= 3 * @stall_timeout
  end

  test "keeps running an EventQL query while heartbeats arrive" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        send_heartbeats(socket, 3 * @stall_timeout)
        StreamServer.send_line(socket, row_line(1))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(1)
      end)

    assert result == {:ok, [1]}
    assert elapsed >= 3 * @stall_timeout
  end

  test "delivers events that arrive within the stall timeout" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("0"))
        Process.sleep(div(@stall_timeout, 2))
        StreamServer.send_line(socket, event_line("1"))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(2)
      end)

    assert result == {:ok, [expected_event("0"), expected_event("1")]}
  end

  test "delivers rows that arrive within the stall timeout" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, row_line(1))
        Process.sleep(div(@stall_timeout, 2))
        StreamServer.send_line(socket, row_line(2))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(2)
      end)

    assert result == {:ok, [1, 2]}
  end

  test "ends observing events without a stalled connection if the caller stops reading" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [expected_event("0")]}
    assert elapsed < @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends reading events as a stalled connection if nothing arrives for the stall timeout" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert {:raised, %ConnectionStalled{}} = result
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps reading events while each of them arrives within the stall timeout" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)

        for id <- 0..3 do
          StreamServer.send_line(socket, event_line(Integer.to_string(id)))
          Process.sleep(div(@stall_timeout, 2))
        end
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(4)
      end)

    assert result == {:ok, Enum.map(0..3, &expected_event(Integer.to_string(&1)))}
    assert elapsed >= @stall_timeout
  end

  test "fails to observe events if the response does not arrive" do
    client = start_server(fn _socket -> :ok end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events(client, "/test")
      end)

    assert result == {:ok, {:error, ConnectionStalled.new(@stall_timeout)}}

    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "names the stall timeout in the error of a stalled connection" do
    client =
      start_server(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {{:raised, error}, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert Exception.message(error) ==
             "Connection stalled: nothing arrived from the server for 500 milliseconds."
  end

  # Every client of these tests waits for the server for the stall timeout.
  defp start_server(script, options \\ []) do
    StreamServer.start(script, Keyword.put_new(options, :stall_timeout, @stall_timeout))
  end

  # Sends the data in the given number of parts, each after a heartbeat
  # interval.
  defp send_parts(socket, data, count) do
    data
    |> split_into_parts(div(byte_size(data) + count - 1, count))
    |> Enum.each(fn part ->
      Process.sleep(@heartbeat_interval)
      StreamServer.send_data(socket, part)
    end)
  end

  defp split_into_parts(data, size) when byte_size(data) > size do
    <<part::binary-size(size), rest::binary>> = data
    [part | split_into_parts(rest, size)]
  end

  defp split_into_parts(data, _size), do: [data]

  defp send_heartbeats(socket, duration) do
    for _ <- 1..div(duration, @heartbeat_interval) do
      StreamServer.send_line(socket, @heartbeat)
      Process.sleep(@heartbeat_interval)
    end
  end

  defp event_line(id) do
    %{"type" => "event", "payload" => event_payload(id)}
  end

  # The event that the client SDK makes of the payload, which keeps the text of
  # its data as the line carried it.
  defp expected_event(id) do
    payload = event_payload(id)
    Event.new(payload, Jason.encode!(payload["data"]))
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
