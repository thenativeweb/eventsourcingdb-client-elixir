defmodule EventSourcingDBTest.StreamErrors do
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.Errors.DBError
  alias EventSourcingDB.Errors.InvalidResponseType
  alias EventSourcingDB.Errors.InvalidServerHeader
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDBTest.StreamServer
  use ExUnit.Case, async: true

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}
  @error %{"type" => "error", "payload" => %{"error" => "something went wrong"}}

  test "raises an error from the database that arrives while reading events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
        StreamServer.send_line(socket, @error)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:raised, %DBError{payload: @error["payload"]}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises an error from the database that arrives while observing events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, @heartbeat)
        StreamServer.send_line(socket, @error)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:raised, %DBError{payload: @error["payload"]}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises an error from the database that arrives while running an EventQL query" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, %{"type" => "row", "payload" => 1})
        StreamServer.send_line(socket, @error)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        {:ok, rows} =
          EventSourcingDB.run_eventql_query(client, "FROM e IN events PROJECT INTO e.data")

        Enum.to_list(rows)
      end)

    assert result == {:raised, %DBError{payload: @error["payload"]}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises an error if a line is not valid JSON" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, %{"type" => "subject", "payload" => %{"subject" => "/"}})
        StreamServer.send_data(socket, "not json\n")
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_subjects!(client, "/") |> Enum.to_list()
      end)

    assert match?({:raised, %Jason.DecodeError{}}, result)
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises an error if a line has an unexpected type" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_event_types!(client) |> Enum.to_list()
      end)

    assert result == {:raised, %InvalidResponseType{expected: "eventType", actual: "event"}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "raises a transmission error if the connection fails while reading events" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_line(socket, event_line("0"))
        :gen_tcp.close(socket)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert match?({:raised, %TransmissionError{}}, result)
  end

  test "fails to read events with the text of an error response, and leaves none of its messages behind" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket, 400, [
          {"server", "EventSourcingDB/test"},
          {"content-type", "text/plain; charset=utf-8"}
        ])

        StreamServer.send_data(socket, "malformed ")
        Process.sleep(50)
        StreamServer.send_data(socket, "subject\n")
        StreamServer.send_end(socket)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        result = EventSourcingDB.read_events(client, "invalid")
        Process.sleep(200)

        {result, mailbox()}
      end)

    assert result == {:ok, {{:error, %ApiError{reason: "malformed subject\n"}}, []}}
  end

  test "fails to observe events from a server that is not EventSourcingDB, and closes the connection" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket, 200, [
          {"server", "SomethingElse/1.0"},
          {"content-type", "application/x-ndjson"}
        ])

        for _ <- 1..10 do
          StreamServer.send_line(socket, @heartbeat)
          Process.sleep(50)
        end
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        result = EventSourcingDB.observe_events(client, "/test")
        Process.sleep(200)

        {result, mailbox()}
      end)

    assert result == {:ok, {{:error, %InvalidServerHeader{}}, []}}
    assert_receive {:stream_server, :closed}, 1_000
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
