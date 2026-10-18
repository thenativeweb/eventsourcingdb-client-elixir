defmodule EventSourcingDBTest.StallTimeout do
  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDBTest.StreamServer
  import EventSourcingDBTest.Utils

  # These tests measure how long a request takes, so they do not run
  # concurrently with others.
  use ExUnit.Case, async: false

  @stall_timeout 500
  @interval 100

  @json_headers [
    {"server", "EventSourcingDB/test"},
    {"content-type", "application/json"}
  ]

  @ping_received %{
    "specversion" => "1.0",
    "type" => "io.eventsourcingdb.api.ping-received",
    "source" => "https://www.eventsourcingdb.io",
    "id" => "0",
    "time" => "2026-10-18T12:00:00.000000000Z",
    "subject" => "/api/v1/ping",
    "datacontenttype" => "application/json",
    "data" => %{"message" => "My God, it's full of stars."}
  }

  @timeout_error %TransmissionError{reason: %Req.TransportError{reason: :timeout}}

  describe "the client" do
    test "waits 30 seconds by default" do
      assert Client.new("http://localhost:3000", "secret").stall_timeout == 30_000

      assert Client.new(base_url: "http://localhost:3000", api_token: "secret").stall_timeout ==
               30_000
    end

    test "takes a stall timeout in milliseconds" do
      client =
        Client.new(base_url: "http://localhost:3000", api_token: "secret", stall_timeout: 5_000)

      assert client.stall_timeout == 5_000
    end

    test "refuses a stall timeout that is not a positive integer" do
      for stall_timeout <- [0, -1, 1.5, :infinity, "5000", nil] do
        assert_raise ArgumentError, fn ->
          Client.new(
            base_url: "http://localhost:3000",
            api_token: "secret",
            stall_timeout: stall_timeout
          )
        end
      end
    end
  end

  for protocol <- [:http1, :http2] do
    describe "over #{protocol}" do
      @protocol protocol

      test "pings while the response arrives" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection, 200, @json_headers)
              StreamServer.send_data(connection, Jason.encode!(@ping_received))
              StreamServer.send_end(connection)
            end,
            protocol: @protocol
          )

        {result, _elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client), mailbox()}
          end)

        assert result == {:ok, {:ok, []}}
      end

      test "fails to ping with a transmission error if the response does not arrive" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client), mailbox()}
          end)

        assert result == {:ok, {{:error, @timeout_error}, []}}
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "fails to write events with a transmission error if the body stops arriving" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection, 200, @json_headers)
              StreamServer.send_data(connection, "[{\"source\":")
            end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.write_events(client, [candidate()]), mailbox()}
          end)

        assert result == {:ok, {{:error, @timeout_error}, []}}
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "registers an event schema while the body arrives in parts, even if they take longer than the stall timeout" do
        body =
          Jason.encode!(%{
            "specversion" => "1.0",
            "type" => "io.eventsourcingdb.api.event-schema-registered",
            "source" => "https://www.eventsourcingdb.io",
            "id" => "0",
            "time" => "2026-10-18T12:00:00.000000000Z",
            "subject" => "/api/v1/register-event-schema",
            "datacontenttype" => "application/json",
            "data" => %{"eventType" => "io.eventsourcingdb.test"}
          })

        parts = 2 * div(@stall_timeout, @interval)
        size = div(byte_size(body), parts) + 1

        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection, 200, @json_headers)

              for part <- split_into_parts(body, size) do
                Process.sleep(@interval)
                StreamServer.send_data(connection, part)
              end

              StreamServer.send_end(connection)
            end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{
              "type" => "object"
            })
          end)

        assert {:ok, {:ok, %EventSourcingDB.ManagementEvent{}}} = result
        assert elapsed >= 2 * @stall_timeout
      end

      test "fails to read an event type with the text of an error response" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection, 404, [
                {"server", "EventSourcingDB/test"},
                {"content-type", "text/plain; charset=utf-8"}
              ])

              StreamServer.send_data(connection, "event type not found\n")
              StreamServer.send_end(connection)
            end,
            protocol: @protocol
          )

        {result, _elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.read_event_type(client, "io.eventsourcingdb.test"), mailbox()}
          end)

        assert result == {:ok, {{:error, %ApiError{reason: "event type not found\n"}}, []}}
      end

      test "fails to ping with a transmission error if the response is not valid JSON" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection, 200, @json_headers)
              StreamServer.send_data(connection, "not json")
              StreamServer.send_end(connection)
            end,
            protocol: @protocol
          )

        {result, _elapsed} =
          StreamServer.run_with_guard(fn ->
            EventSourcingDB.ping(client)
          end)

        assert {:ok, {:error, %TransmissionError{reason: %Jason.DecodeError{}}}} = result
      end

      test "fails to read events with a transmission error if the response does not arrive" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            EventSourcingDB.read_events(client, "/test")
          end)

        assert result == {:ok, {:error, @timeout_error}}
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end
    end
  end

  test "fails to ping after a shorter receive timeout that the client passes on to Req" do
    receive_timeout = div(@stall_timeout, 2)

    client =
      start_server(fn _socket -> :ok end, req_options: [receive_timeout: receive_timeout])

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert result == {:ok, {:error, @timeout_error}}
    assert elapsed >= receive_timeout
    assert elapsed < @stall_timeout
  end

  test "fails to ping after the stall timeout, even if the client passes a longer receive timeout on to Req" do
    client =
      start_server(fn _socket -> :ok end, req_options: [receive_timeout: 4 * @stall_timeout])

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert result == {:ok, {:error, @timeout_error}}
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
  end

  # Requests run in a process of their own, which takes the calling process
  # for one of its callers, so that what the caller is allowed, such as the
  # stubs of Req.Test, holds for that process as well.
  test "runs a request with the calling process among its callers, as a task does" do
    test_process = self()

    report_callers = fn req ->
      Req.Request.prepend_request_steps(req,
        report_callers: fn request ->
          send(test_process, {:callers, self(), Process.get(:"$callers")})
          request
        end
      )
    end

    client =
      start_server(
        fn socket ->
          StreamServer.send_head(socket, 200, @json_headers)
          StreamServer.send_data(socket, Jason.encode!(@ping_received))
          StreamServer.send_end(socket)
        end,
        req_options: [plugins: [report_callers]]
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        {self(), EventSourcingDB.ping(client)}
      end)

    assert {:ok, {caller, :ok}} = result
    assert_receive {:callers, process, [^caller | callers]}
    assert process != caller
    assert test_process in callers
  end

  # Every client of these tests waits for the server for the stall timeout.
  defp start_server(script, options) do
    StreamServer.start(script, Keyword.put_new(options, :stall_timeout, @stall_timeout))
  end

  defp candidate() do
    create_test_eventcandidate("/test", %{"value" => 1})
  end

  defp split_into_parts(data, size) when byte_size(data) > size do
    <<part::binary-size(size), rest::binary>> = data
    [part | split_into_parts(rest, size)]
  end

  defp split_into_parts(data, _size), do: [data]

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end
end
