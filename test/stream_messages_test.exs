defmodule EventSourcingDBTest.StreamMessages do
  alias EventSourcingDBTest.StreamServer
  use ExUnit.Case, async: true

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}

  test "leaves the other messages of the process in its mailbox while reading events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
        Process.sleep(100)
        StreamServer.send_line(socket, event_line("1"))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        send(self(), :before_reading)

        events =
          EventSourcingDB.read_events!(client, "/test")
          |> Stream.each(fn event -> send(self(), {:while_reading, event.id}) end)
          |> Enum.take(2)

        {Enum.map(events, & &1.id), mailbox()}
      end)

    assert result ==
             {:ok, {["0", "1"], [:before_reading, {:while_reading, "0"}, {:while_reading, "1"}]}}
  end

  test "leaves the other messages of the process in its mailbox while observing events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("0"))
        Process.sleep(100)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, event_line("1"))
      end)

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
  end

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp event_line(id) do
    %{
      "type" => "event",
      "payload" => %{
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
    }
  end
end
