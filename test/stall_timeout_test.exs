# Stands in for the context of OpenTelemetry, which the client SDK takes over
# into the relay if OpenTelemetry is loaded, without depending on it.
defmodule :otel_ctx do
  @moduledoc false

  def get_current(), do: Process.get(:otel_ctx_current, %{})
  def attach(context), do: Process.put(:otel_ctx_current, context)
end

defmodule EventSourcingDBTest.StallTimeout do
  alias EventSourcingDB.{Client, EventType, ManagementEvent}
  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.Errors.ConnectionStalled
  alias EventSourcingDB.Errors.DbApiError
  alias EventSourcingDB.Errors.OutcomeUnknown
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.Transport.ApiVersion
  alias EventSourcingDBTest.{FakeServer, StreamServer}
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

  @schema_registered %{
    "specversion" => "1.0",
    "type" => "io.eventsourcingdb.api.event-schema-registered",
    "source" => "https://www.eventsourcingdb.io",
    "id" => "0",
    "time" => "2026-10-18T12:00:00.000000000Z",
    "subject" => "/api/v1/register-event-schema",
    "datacontenttype" => "application/json",
    "data" => %{"eventType" => "io.eventsourcingdb.test"}
  }

  @event_type_read %{
    "type" => "eventType",
    "data" => %{"type" => "io.eventsourcingdb.test", "hasEvents" => false}
  }

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

      test "fails to ping as a stalled connection if the response does not arrive" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client), mailbox()}
          end)

        assert {:ok, {{:error, %ConnectionStalled{}}, []}} = result
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "fails to write events with an unknown outcome if the body stops arriving" do
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

        assert {:ok, {{:error, %OutcomeUnknown{cause: %ConnectionStalled{}}}, []}} = result
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

        assert result ==
                 {:ok,
                  {{:error,
                    %DbApiError{
                      status: 404,
                      code: ErrorCode.event_type_unknown(),
                      description: "event type not found\n"
                    }}, []}}
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

      test "fails to read events as a stalled connection if the response does not arrive" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            EventSourcingDB.read_events(client, "/test")
          end)

        assert {:ok, {:error, %ConnectionStalled{}}} = result
        assert elapsed >= @stall_timeout
        assert elapsed < 2 * @stall_timeout
        assert_receive {:stream_server, :closed}, 1_000
      end
    end
  end

  # Every block of an answer restarts the stall timeout, also over HTTP/2,
  # where Finch bounds a whole request with the receive timeout rather than
  # each wait for data, so that a request with a single answer is not cut off
  # while its answer keeps arriving, with or without a timeout of the call.
  for protocol <- [:http1, :http2] do
    @protocol protocol

    test "registers an event schema through the v1 API over #{protocol} while the answer arrives in parts, even if they take longer than the stall timeout" do
      client = start_server(&send_in_parts(&1, @schema_registered), protocol: @protocol)

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{
            "type" => "object"
          })
        end)

      assert {:ok, {:ok, %ManagementEvent{}}} = result
      assert elapsed >= 2 * @stall_timeout
    end

    test "reads an event type through the v2 API over #{protocol} while the answer arrives in parts, even if they take longer than the stall timeout" do
      client = start_server(&send_in_parts(&1, @event_type_read), protocol: @protocol, api: :v2)

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_event_type(client, "io.eventsourcingdb.test")
        end)

      assert {:ok, {:ok, %EventType{type: "io.eventsourcingdb.test"}}} = result
      assert elapsed >= 2 * @stall_timeout
    end

    test "registers an event schema with a timeout over #{protocol} while the answer arrives in parts, even if they take longer than the stall timeout" do
      client = start_server(&send_in_parts(&1, @schema_registered), protocol: @protocol)

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.register_event_schema(
            client,
            "io.eventsourcingdb.test",
            %{"type" => "object"},
            timeout: 4 * @stall_timeout
          )
        end)

      assert {:ok, {:ok, %ManagementEvent{}}} = result
      assert elapsed >= 2 * @stall_timeout
    end
  end

  test "fails to ping after the receive timeout that the client passes on to Req, if it sets no stall timeout" do
    receive_timeout = div(@stall_timeout, 2)

    client =
      StreamServer.start(fn _socket -> :ok end, req_options: [receive_timeout: receive_timeout])

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        EventSourcingDB.ping(client)
      end)

    assert {:ok, {:error, %ConnectionStalled{}}} = result
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

    assert {:ok, {:error, %ConnectionStalled{}}} = result
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

    assert {:ok, {:error, %ConnectionStalled{}}} = result
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

    assert {:ok, {:error, %ConnectionStalled{}}} = result
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

  # Every request makes a single attempt, a ping as well, although it is a GET
  # request, which Req would otherwise retry three times after a timeout, after
  # about one, two, and four seconds. So a ping to a server that stalls fails
  # once the stall timeout has passed, whether it stalls while the client asks
  # for the API before the first ping, which is a GET request as well, or as
  # the ping itself.
  @tag capture_log: true
  test "fails to ping after the stall timeout of a single attempt to ask for the API" do
    base_url = start_silent_server()
    client = Client.new(base_url: base_url, api_token: "secret", stall_timeout: @stall_timeout)

    {result, elapsed} = measure_within_watchdog(fn -> EventSourcingDB.ping(client) end)

    assert accepted_connections() == 1
    assert {:error, %ConnectionStalled{}} = result
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
  end

  for api <- [:v1, :v2] do
    @api api

    @tag capture_log: true
    test "fails to ping through the #{api} API after the stall timeout of a single attempt" do
      base_url = start_silent_server()
      client = Client.new(base_url: base_url, api_token: "secret", stall_timeout: @stall_timeout)
      :ok = ApiVersion.remember(client, @api)

      {result, elapsed} = measure_within_watchdog(fn -> EventSourcingDB.ping(client) end)

      assert accepted_connections() == 1
      assert {:error, %ConnectionStalled{}} = result
      assert elapsed >= @stall_timeout
      assert elapsed < 2 * @stall_timeout
    end
  end

  # A call that starts while a ping asks for the API shares the answer of that
  # single attempt, rather than ask on its own.
  @tag capture_log: true
  test "fails to write events once the attempt to ask for the API that a ping began has stalled" do
    base_url = start_silent_server()
    client = Client.new(base_url: base_url, api_token: "secret", stall_timeout: @stall_timeout)

    ping = Task.async(fn -> EventSourcingDB.ping(client) end)
    assert_receive :accepted, @stall_timeout

    {result, elapsed} =
      measure_within_watchdog(fn -> EventSourcingDB.write_events(client, [candidate()]) end)

    assert accepted_connections() == 0
    assert {:error, %ConnectionStalled{}} = result
    assert elapsed < 2 * @stall_timeout
    assert {:error, %ConnectionStalled{}} = Task.await(ping)
  end

  # Nor does a ping make another attempt after any other error, such as a
  # connection that the server closes without an answer.
  test "fails to ask for the API before a ping after a single attempt if the server closes the connection" do
    client = Client.new(FakeServer.start(fn _request -> :close end), "secret")

    {result, _elapsed} = measure_within_watchdog(fn -> EventSourcingDB.ping(client) end)

    assert requests_received() == 1
    assert {:error, %TransmissionError{}} = result
  end

  for api <- [:v1, :v2] do
    @api api

    test "fails to ping through the #{api} API after a single attempt if the server closes the connection" do
      client = Client.new(FakeServer.start(fn _request -> :close end), "secret")
      :ok = ApiVersion.remember(client, @api)

      {result, _elapsed} = measure_within_watchdog(fn -> EventSourcingDB.ping(client) end)

      assert requests_received() == 1
      assert {:error, %TransmissionError{}} = result
    end
  end

  # Req retries as its own retry option says, which the client passes on.
  @tag capture_log: true
  test "pings as often as the retry option that the client passes on to Req says" do
    client =
      Client.new(
        base_url: FakeServer.start(fn _request -> :close end),
        api_token: "secret",
        req_options: [retry: :safe_transient, retry_delay: fn _retry_count -> 0 end]
      )

    :ok = ApiVersion.remember(client, :v1)

    {result, _elapsed} = measure_within_watchdog(fn -> EventSourcingDB.ping(client) end)

    assert requests_received() == 4
    assert {:error, %TransmissionError{}} = result
  end

  # Before its first request, a client asks the server for its API with a GET
  # request, so that a write that stalls while it asks fails after a single
  # attempt, and was not sent.
  @tag capture_log: true
  test "fails to write events after the stall timeout of a single attempt to ask for the API" do
    base_url = start_silent_server()
    client = Client.new(base_url: base_url, api_token: "secret", stall_timeout: @stall_timeout)

    {result, elapsed} = measure(fn -> EventSourcingDB.write_events(client, [candidate()]) end)

    assert {:error, %ConnectionStalled{}} = result
    assert accepted_connections() == 1
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
  end

  @tag capture_log: true
  test "fails to write events with an unknown outcome after the stall timeout of a single attempt" do
    base_url = start_silent_server()
    client = Client.new(base_url: base_url, api_token: "secret", stall_timeout: @stall_timeout)
    :ok = ApiVersion.remember(client, :v1)

    {result, elapsed} = measure(fn -> EventSourcingDB.write_events(client, [candidate()]) end)

    assert {:error, %OutcomeUnknown{cause: %ConnectionStalled{}}} = result
    assert accepted_connections() == 1
    assert elapsed >= @stall_timeout
    assert elapsed < 2 * @stall_timeout
  end

  # Starts a server that accepts every connection and never answers, and sends
  # :accepted to the calling process for each connection.
  defp start_silent_server() do
    owner = self()
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    start_supervised!({Task, fn -> accept_silently(listen_socket, owner) end})

    # Neither the API that a server on the same port left behind before, nor
    # the API that a test remembers for this one, may outlive the server.
    url = "http://127.0.0.1:#{port}"
    client = Client.new(url, "secret")
    :ok = ApiVersion.forget(client)
    on_exit(fn -> ApiVersion.forget(client) end)
    url
  end

  # Keeps every connection open, since the task owns its socket.
  defp accept_silently(listen_socket, owner) do
    {:ok, _socket} = :gen_tcp.accept(listen_socket)
    send(owner, :accepted)
    accept_silently(listen_socket, owner)
  end

  defp accepted_connections(count \\ 0) do
    receive do
      :accepted -> accepted_connections(count + 1)
    after
      0 -> count
    end
  end

  # Every request has arrived once the call returns, since Req makes its
  # retries, if any, before it returns.
  defp requests_received(count \\ 0) do
    receive do
      {:fake_server, :request, _request} -> requests_received(count + 1)
    after
      0 -> count
    end
  end

  defp measure(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started_at}
  end

  # Measures the function in a process of its own, and fails the test should
  # it not return in time. A call that is retried after it stalled takes about
  # eight seconds with the stall timeout of these tests, and one that nothing
  # bounds never returns.
  @watchdog_timeout 15_000

  defp measure_within_watchdog(fun) do
    task = Task.async(fn -> measure(fun) end)

    case Task.yield(task, @watchdog_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, measured} -> measured
      _other -> flunk("The call did not return within #{@watchdog_timeout} ms.")
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

  # Answers with the item, whose text arrives in parts, one every interval,
  # over twice the stall timeout. Each part holds at least one byte, since an
  # empty chunk would end the answer over HTTP/1.
  defp send_in_parts(connection, item) do
    body = Jason.encode!(item)
    count = 2 * div(@stall_timeout, @interval)
    boundaries = Enum.map(0..count, &div(&1 * byte_size(body), count))

    StreamServer.send_head(connection, 200, @json_headers)

    for [from, to] <- Enum.chunk_every(boundaries, 2, 1, :discard) do
      Process.sleep(@interval)
      StreamServer.send_data(connection, binary_part(body, from, to - from))
    end

    StreamServer.send_end(connection)
  end

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end
end
