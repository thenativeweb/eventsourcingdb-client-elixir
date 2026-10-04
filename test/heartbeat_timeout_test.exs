defmodule EventSourcingDBTest.HeartbeatTimeout do
  alias EventSourcingDB.Errors.HeartbeatTimeout
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.Event
  alias EventSourcingDBTest.StreamServer

  # The heartbeat timeout is shortened through the application environment,
  # which is global, so these tests must not run concurrently with others.
  use ExUnit.Case, async: false

  @heartbeat_timeout 500
  @heartbeat_interval 100

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}

  setup do
    Application.put_env(:eventsourcingdb, :heartbeat_timeout, @heartbeat_timeout)
    on_exit(fn -> Application.delete_env(:eventsourcingdb, :heartbeat_timeout) end)
  end

  test "ends observing events with a heartbeat timeout if nothing arrives" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %HeartbeatTimeout{}}, result)
    assert elapsed >= @heartbeat_timeout
    assert elapsed < 2 * @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends running an EventQL query with a heartbeat timeout if nothing arrives" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e")
        |> Enum.to_list()
      end)

    assert match?({:raised, %HeartbeatTimeout{}}, result)
    assert elapsed >= @heartbeat_timeout
    assert elapsed < 2 * @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends observing events with a heartbeat timeout even if other messages arrive" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        reader = self()

        spawn_link(fn ->
          for i <- 1..div(2 * @heartbeat_timeout, @heartbeat_interval) do
            send(reader, {:unrelated, i})
            Process.sleep(@heartbeat_interval)
          end
        end)

        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %HeartbeatTimeout{}}, result)
    assert elapsed >= @heartbeat_timeout
    assert elapsed < 2 * @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "ends observing events with a heartbeat timeout if only parts of a line arrive" do
    line = Jason.encode!(event_line("0")) <> "\n"

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)

        # The first bytes of the line, one after the other, which do not
        # complete it within twice the heartbeat timeout.
        for <<byte <- binary_part(line, 0, div(2 * @heartbeat_timeout, @heartbeat_interval))>> do
          Process.sleep(@heartbeat_interval)
          StreamServer.send_data(socket, <<byte>>)
        end
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %HeartbeatTimeout{}}, result)
    assert elapsed >= @heartbeat_timeout
    assert elapsed < 2 * @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "keeps observing events while heartbeats arrive" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_heartbeats(socket, 3 * @heartbeat_timeout)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [Event.new(event_payload("0"))]}
    assert elapsed >= 3 * @heartbeat_timeout
  end

  test "keeps running an EventQL query while heartbeats arrive" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_heartbeats(socket, 3 * @heartbeat_timeout)
        StreamServer.send_line(socket, row_line(1))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(1)
      end)

    assert result == {:ok, [1]}
    assert elapsed >= 3 * @heartbeat_timeout
  end

  test "delivers events that arrive within the heartbeat timeout" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("0"))
        Process.sleep(div(@heartbeat_timeout, 2))
        StreamServer.send_line(socket, event_line("1"))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(2)
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "delivers rows that arrive within the heartbeat timeout" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, row_line(1))
        Process.sleep(div(@heartbeat_timeout, 2))
        StreamServer.send_line(socket, row_line(2))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(2)
      end)

    assert result == {:ok, [1, 2]}
  end

  test "ends observing events without a heartbeat timeout if the caller stops reading" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [Event.new(event_payload("0"))]}
    assert elapsed < @heartbeat_timeout
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "does not apply the heartbeat timeout to reading events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
        Process.sleep(2 * @heartbeat_timeout)
        StreamServer.send_line(socket, event_line("1"))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(2)
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "fails to observe events if the response does not arrive" do
    client = StreamServer.start(fn _socket -> :ok end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events(client, "/test")
      end)

    assert match?({:ok, {:error, %TransmissionError{}}}, result)
  end

  defp send_heartbeats(socket, duration) do
    for _ <- 1..div(duration, @heartbeat_interval) do
      StreamServer.send_line(socket, @heartbeat)
      Process.sleep(@heartbeat_interval)
    end
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
