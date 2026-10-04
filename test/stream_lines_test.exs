defmodule EventSourcingDBTest.StreamLines do
  alias EventSourcingDB.Errors.DBError
  alias EventSourcingDB.Event
  alias EventSourcingDBTest.StreamServer
  use ExUnit.Case, async: true

  @heartbeat %{"type" => "heartbeat", "payload" => %{}}
  @error %{"type" => "error", "payload" => %{"error" => "something went wrong"}}

  # A pause between two blocks, so that they arrive separately.
  @pause 20

  test "reads an event whose line arrives in several blocks" do
    line = encode(event_line("0"))

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_parts(socket, line, [10, 100, 150])
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [Event.new(event_payload("0"))]}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "reads an event whose line is split inside a multibyte character" do
    line = encode(event_line("0", "Grüße – 1 €"))

    # The euro sign takes three bytes, and the line is split after the first
    # and after the second of them.
    {euro, 3} = :binary.match(line, "€")

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_parts(socket, line, [euro + 1, euro + 2])
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(1)
      end)

    assert result == {:ok, [Event.new(event_payload("0", "Grüße – 1 €"))]}
  end

  test "reads several lines that arrive in one block" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)

        StreamServer.send_data(
          socket,
          encode(event_line("0")) <> encode(@heartbeat) <> encode(event_line("1"))
        )
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.observe_events!(client, "/test") |> Enum.take(2)
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
    assert_receive {:stream_server, :closed}, 1_000
  end

  test "reads the rows of a query whose lines arrive in blocks of any size" do
    data = Enum.map_join(1..3, &encode(%{"type" => "row", "payload" => &1}))

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_parts(socket, data, [5, 30, 31, 60])
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e.data.value")
        |> Enum.take(3)
      end)

    assert result == {:ok, [1, 2, 3]}
  end

  test "reads lines that are split exactly at the newline" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_data(socket, Jason.encode!(event_line("0")))
        Process.sleep(@pause)
        StreamServer.send_data(socket, "\n")
        Process.sleep(@pause)
        StreamServer.send_data(socket, encode(event_line("1")))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.take(2)
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "reads the last line up to the end of the response if it ends with a newline" do
    data = encode(event_line("0")) <> encode(event_line("1"))

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_parts(socket, data, [byte_size(data) - 20])
        StreamServer.send_end(socket)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "reads the last line up to the end of the response if it lacks a newline" do
    data = encode(event_line("0")) <> Jason.encode!(event_line("1"))

    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        send_parts(socket, data, [byte_size(data) - 20])
        StreamServer.send_end(socket)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "skips empty lines" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_data(socket, "\n" <> encode(event_line("0")) <> "\n\n")
        Process.sleep(@pause)
        StreamServer.send_data(socket, "\n")
        StreamServer.send_line(socket, event_line("1"))
        StreamServer.send_end(socket)
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
      end)

    assert result == {:ok, [Event.new(event_payload("0")), Event.new(event_payload("1"))]}
  end

  test "delivers the lines before an error that arrives in the same block" do
    client =
      StreamServer.start(fn socket ->
        StreamServer.send_head(socket)
        StreamServer.send_data(socket, encode(event_line("0")) <> encode(@error))
      end)

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        try do
          EventSourcingDB.read_events!(client, "/test")
          |> Stream.each(fn event -> send(self(), {:read, event.id}) end)
          |> Enum.to_list()
        rescue
          exception -> {exception, mailbox()}
        end
      end)

    assert result == {:ok, {%DBError{payload: @error["payload"]}, [{:read, "0"}]}}
    assert_receive {:stream_server, :closed}, 1_000
  end

  # Sends the data in parts, split at the given byte offsets.
  defp send_parts(socket, data, offsets) do
    [0 | offsets]
    |> Enum.zip(offsets ++ [byte_size(data)])
    |> Enum.each(fn {from, to} ->
      StreamServer.send_data(socket, binary_part(data, from, to - from))
      Process.sleep(@pause)
    end)
  end

  defp encode(line) do
    Jason.encode!(line) <> "\n"
  end

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp event_line(id, value \\ nil) do
    %{"type" => "event", "payload" => event_payload(id, value)}
  end

  defp event_payload(id, value \\ nil) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "time" => "2026-10-03T12:00:00.000000000Z",
      "source" => "https://EventSourcingDB.io",
      "subject" => "/test",
      "type" => "io.eventsourcingdb.test",
      "datacontenttype" => "application/json",
      "data" => %{"value" => value || id},
      "hash" => String.duplicate("0", 64),
      "predecessorhash" => String.duplicate("0", 64)
    }
  end
end
