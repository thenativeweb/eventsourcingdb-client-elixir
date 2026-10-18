# Stands in for the context of OpenTelemetry, which the client SDK takes over
# into the relay if OpenTelemetry is loaded, without depending on it.
defmodule :otel_ctx do
  @moduledoc false

  def get_current(), do: Process.get(:otel_ctx_current, %{})
  def attach(context), do: Process.put(:otel_ctx_current, context)
end

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
    test "sets no stall timeout by default, and does not take one from the req_options" do
      assert Client.new("http://localhost:3000", "secret").stall_timeout == nil

      client =
        Client.new(
          base_url: "http://localhost:3000",
          api_token: "secret",
          req_options: [receive_timeout: 60_000]
        )

      assert client.stall_timeout == nil
    end

    test "keeps the stall timeout, even if it passes a receive timeout on to Req" do
      client =
        Client.new(
          base_url: "http://localhost:3000",
          api_token: "secret",
          req_options: [receive_timeout: 60_000],
          stall_timeout: 5_000
        )

      assert client.stall_timeout == 5_000
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

        assert {:ok, {{:error, %TransmissionError{reason: %{reason: :timeout}}}, []}} = result
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

        assert {:ok, {{:error, %TransmissionError{reason: %{reason: :timeout}}}, []}} = result
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
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

        assert {:ok, {:error, %TransmissionError{reason: %{reason: :timeout}}}} = result
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end
    end
  end

  # Over HTTP/2, Finch bounds a whole request with a single answer with the
  # receive timeout, which is the stall timeout, rather than each wait for data.
  test "registers an event schema over HTTP/1 while the body arrives in parts, even if they take longer than the stall timeout" do
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
        []
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

  test "fails to ping after the receive timeout that the client passes on to Req, if it sets no stall timeout" do
    receive_timeout = div(@stall_timeout, 2)

    client =
      StreamServer.start(fn _socket -> :ok end, req_options: [receive_timeout: receive_timeout])

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert result == {:ok, {:error, @timeout_error}}
    assert elapsed >= receive_timeout
    assert elapsed < @stall_timeout
  end

  test "keeps observing events while heartbeats arrive less often than the receive timeout that the client passes on to Req" do
    receive_timeout = div(@stall_timeout, 2)

    client =
      StreamServer.start(
        fn socket ->
          StreamServer.send_head(socket)

          for _ <- 1..4 do
            StreamServer.send_line(socket, %{"type" => "heartbeat", "payload" => %{}})
            Process.sleep(receive_timeout + @interval)
          end

          StreamServer.send_line(socket, %{"type" => "row", "payload" => 1})
        end,
        req_options: [receive_timeout: receive_timeout]
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO 1")
        |> Enum.take(1)
      end)

    assert result == {:ok, [1]}
    assert elapsed >= 4 * receive_timeout
  end

  test "keeps Req's connect timeout if the client sets no stall timeout, even if it passes a receive timeout on to Req" do
    assert ping_reporting_connect_options(req_options: [receive_timeout: div(@stall_timeout, 2)]) ==
             :ok

    assert_received {:connect_options, nil}
  end

  test "bounds connecting with the stall timeout if the client sets one" do
    assert ping_reporting_connect_options(
             req_options: [receive_timeout: div(@stall_timeout, 2)],
             stall_timeout: @stall_timeout
           ) == :ok

    assert_received {:connect_options, [timeout: @stall_timeout]}
  end

  test "fails to ping after the receive timeout of the req_options that the client was given after it was created" do
    receive_timeout = div(@stall_timeout, 2)
    client = StreamServer.start(fn _socket -> :ok end)
    client = %{client | req_options: client.req_options ++ [receive_timeout: receive_timeout]}

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert result == {:ok, {:error, @timeout_error}}
    assert elapsed >= receive_timeout
    assert elapsed < @stall_timeout
  end

  test "fails to ping after the stall timeout, even if the client passes a shorter receive timeout on to Req" do
    client =
      start_server(fn _socket -> :ok end, req_options: [receive_timeout: div(@stall_timeout, 2)])

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert result == {:ok, {:error, @timeout_error}}
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
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

  test "runs a request with a single answer in the calling process" do
    test_process = self()

    client =
      start_server(
        fn socket ->
          StreamServer.send_head(socket, 200, @json_headers)
          StreamServer.send_data(socket, Jason.encode!(@ping_received))
          StreamServer.send_end(socket)
        end,
        req_options: [plugins: [report_process(test_process)]]
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        {self(), EventSourcingDB.ping(client)}
      end)

    assert {:ok, {caller, :ok}} = result
    assert_receive {:process, ^caller, _context}
  end

  # A stream with heartbeats runs in a process of its own, which takes over the
  # callers, the Logger metadata, and the OpenTelemetry context of the calling
  # process, so that the steps of the request see what they would have seen
  # in the calling process.
  test "runs a stream with heartbeats with the callers, the Logger metadata, and the OpenTelemetry context of the calling process" do
    test_process = self()

    client =
      start_server(
        fn socket ->
          StreamServer.send_head(socket)
          StreamServer.send_line(socket, %{"type" => "row", "payload" => 1})
        end,
        req_options: [plugins: [report_process(test_process)]]
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        # The metadata of the calling process, whose keys a test need not
        # configure for Logger.
        metadata = [request_id: "4711"]
        Logger.metadata(metadata)
        :otel_ctx.attach(%{span: "4712"})

        rows =
          EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO 1")
          |> Enum.take(1)

        {self(), rows}
      end)

    assert {:ok, {caller, [1]}} = result
    assert_receive {:process, process, context}
    assert process != caller
    assert [^caller | callers] = context.callers
    assert test_process in callers
    assert context.logger_metadata[:request_id] == "4711"
    assert context.otel_context == %{span: "4712"}
  end

  for protocol <- [:http1, :http2] do
    @protocol protocol

    test "closes the connection of a stream with heartbeats over #{protocol} once the calling process is down" do
      client =
        StreamServer.start(
          fn connection ->
            StreamServer.send_head(connection)
            StreamServer.send_line(connection, %{"type" => "heartbeat", "payload" => %{}})
          end,
          protocol: @protocol
        )

      {caller, monitor} =
        spawn_monitor(fn ->
          EventSourcingDB.observe_events!(client, "/test") |> Stream.run()
        end)

      Process.sleep(200)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
      assert_receive {:stream_server, :closed}, 1_000
    end
  end

  # Pings a server that answers, and sends the connection options of the
  # request to the calling process.
  defp ping_reporting_connect_options(options) do
    test_process = self()

    report_connect_options = fn req ->
      Req.Request.prepend_request_steps(req,
        report_connect_options: fn request ->
          send(
            test_process,
            {:connect_options, Req.Request.get_option(request, :connect_options)}
          )

          request
        end
      )
    end

    options =
      Keyword.update!(options, :req_options, &(&1 ++ [plugins: [report_connect_options]]))

    StreamServer.start(
      fn socket ->
        StreamServer.send_head(socket, 200, @json_headers)
        StreamServer.send_data(socket, Jason.encode!(@ping_received))
        StreamServer.send_end(socket)
      end,
      options
    )
    |> EventSourcingDB.ping()
  end

  # Sends the process that runs the steps of a request, and what it holds, to
  # the given process.
  defp report_process(test_process) do
    fn req ->
      Req.Request.prepend_request_steps(req,
        report_process: fn request ->
          send(
            test_process,
            {:process, self(),
             %{
               callers: Process.get(:"$callers"),
               logger_metadata: Logger.metadata(),
               otel_context: :otel_ctx.get_current()
             }}
          )

          request
        end
      )
    end
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
