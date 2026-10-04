defmodule EventSourcingDBTest.NamedPool do
  alias EventSourcingDB.Errors.HeartbeatTimeout
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

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}

  setup do
    Application.put_env(:eventsourcingdb, :heartbeat_timeout, @heartbeat_timeout)
    on_exit(fn -> Application.delete_env(:eventsourcingdb, :heartbeat_timeout) end)
  end

  describe "through a named HTTP/2 pool" do
    test "keeps observing events while heartbeats arrive" do
      client =
        StreamServer.start(
          fn connection ->
            StreamServer.send_head(connection)
            send_heartbeats(connection, 2 * @receive_timeout)
            StreamServer.send_line(connection, event_line("0"))
          end,
          protocol: :http2,
          req_options: [finch: [name: start_pool(:http2)]]
        )

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
        end)

      assert result == {:ok, [Event.new(event_payload("0"))]}
      assert elapsed >= 2 * @receive_timeout
      assert_receive {:stream_server, :closed}, 1_000
    end

    test "keeps reading events while they arrive" do
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
          req_options: [
            finch: [name: start_pool(:http2)],
            receive_timeout: @client_receive_timeout
          ]
        )

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_events!(client, "/test") |> Enum.take(10)
        end)

      assert result == {:ok, Enum.map(0..9, &Event.new(event_payload(Integer.to_string(&1))))}
      assert elapsed >= 3 * @client_receive_timeout
      assert_receive {:stream_server, :closed}, 1_000
    end
  end

  describe "through a named HTTP/1 pool" do
    test "keeps observing events while heartbeats arrive" do
      client =
        StreamServer.start(
          fn socket ->
            StreamServer.send_head(socket)
            send_heartbeats(socket, 2 * @receive_timeout)
            StreamServer.send_line(socket, event_line("0"))
          end,
          req_options: [finch: [name: start_pool(:http1)]]
        )

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.observe_events!(client, "/test") |> Enum.take(1)
        end)

      assert result == {:ok, [Event.new(event_payload("0"))]}
      assert elapsed >= 2 * @receive_timeout
      assert_receive {:stream_server, :closed}, 1_000
    end

    test "ends observing events with a heartbeat timeout if nothing arrives" do
      client =
        StreamServer.start(
          fn socket ->
            StreamServer.send_head(socket)
            StreamServer.send_line(socket, @heartbeat)
          end,
          req_options: [finch: [name: start_pool(:http1)]]
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

    test "ends reading events with a transmission error if nothing arrives" do
      client =
        StreamServer.start(
          fn socket ->
            StreamServer.send_head(socket)
            StreamServer.send_line(socket, event_line("0"))
          end,
          req_options: [
            finch: [name: start_pool(:http1)],
            receive_timeout: @client_receive_timeout
          ]
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

    test "fails to observe events if the response does not arrive" do
      client =
        StreamServer.start(fn _socket -> :ok end,
          req_options: [finch: [name: start_pool(:http1)]]
        )

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.observe_events(client, "/test")
        end)

      assert match?({:ok, {:error, %TransmissionError{}}}, result)
      assert elapsed >= @receive_timeout
      assert elapsed < 2 * @receive_timeout
      assert_receive {:stream_server, :closed}, 1_000
    end

    test "leaves the other messages of the process, and no message of the response, in its mailbox" do
      client =
        StreamServer.start(
          fn socket ->
            StreamServer.send_head(socket)
            StreamServer.send_line(socket, @heartbeat)
            StreamServer.send_line(socket, event_line("0"))
            Process.sleep(@heartbeat_interval)
            StreamServer.send_line(socket, @heartbeat)
            StreamServer.send_line(socket, event_line("1"))
            StreamServer.send_line(socket, event_line("2"))
          end,
          req_options: [finch: [name: start_pool(:http1)]]
        )

      {result, _elapsed} =
        StreamServer.run_with_guard(fn ->
          send(self(), :before_reading)

          events =
            EventSourcingDB.observe_events!(client, "/test")
            |> Stream.each(fn event -> send(self(), {:while_reading, event.id}) end)
            |> Enum.take(2)

          Process.sleep(@heartbeat_interval)

          {Enum.map(events, & &1.id), mailbox()}
        end)

      assert result ==
               {:ok,
                {["0", "1"], [:before_reading, {:while_reading, "0"}, {:while_reading, "1"}]}}

      assert_receive {:stream_server, :closed}, 1_000
    end
  end

  # Starts a Finch instance of its own, whose pools speak the given protocol,
  # and returns its name.
  defp start_pool(protocol) do
    name = Module.concat(__MODULE__, "Finch#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: name, pools: %{default: [protocols: [protocol]]}})

    name
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
end
