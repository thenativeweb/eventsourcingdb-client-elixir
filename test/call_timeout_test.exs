defmodule EventSourcingDBTest.CallTimeout do
  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.CallTimedOut
  alias EventSourcingDB.Errors.ConnectionStalled
  alias EventSourcingDB.Errors.OutcomeUnknown
  alias EventSourcingDB.ReadSubjectsOptions
  alias EventSourcingDB.Transport.ApiVersion
  alias EventSourcingDBTest.FakeServer
  alias EventSourcingDBTest.StreamServer
  import EventSourcingDBTest.Utils

  # These tests measure how long a call takes, so they do not run
  # concurrently with others.
  use ExUnit.Case, async: false

  @timeout 400
  @stall_timeout 2_000
  @interval 100

  @json_headers [
    {"server", "EventSourcingDB/test"},
    {"content-type", "application/json"}
  ]

  @ping_received %{"type" => "io.eventsourcingdb.api.ping-received"}

  describe "the options of a call" do
    test "take a timeout in milliseconds, which must be a positive integer" do
      client = Client.new("http://127.0.0.1:1", "secret")

      for timeout <- [0, -1, 1.5, :infinity, "5000", nil] do
        for call <- [
              fn -> EventSourcingDB.ping(client, timeout: timeout) end,
              fn -> EventSourcingDB.write_events(client, [candidate()], timeout: timeout) end,
              fn -> EventSourcingDB.write_events(client, [candidate()], [], timeout: timeout) end,
              fn -> EventSourcingDB.read_events(client, "/", timeout: timeout) end,
              fn -> EventSourcingDB.observe_events(client, "/", nil, timeout: timeout) end,
              fn -> EventSourcingDB.run_eventql_query(client, "", timeout: timeout) end,
              fn -> EventSourcingDB.register_event_schema(client, "t", %{}, timeout: timeout) end,
              fn ->
                EventSourcingDB.read_subjects(client, "/", %ReadSubjectsOptions{recursive: true},
                  timeout: timeout
                )
              end,
              fn -> EventSourcingDB.read_event_type(client, "t", timeout: timeout) end,
              fn -> EventSourcingDB.read_event_types(client, timeout: timeout) end,
              fn -> EventSourcingDB.verify_api_token(client, timeout: timeout) end
            ] do
          assert_raise ArgumentError,
                       "expected :timeout to be a positive integer of milliseconds, got: #{inspect(timeout)}",
                       call
        end
      end
    end

    test "take nothing but a timeout" do
      client = Client.new("http://127.0.0.1:1", "secret")

      assert_raise ArgumentError, fn -> EventSourcingDB.ping(client, stall_timeout: 1_000) end
    end
  end

  for protocol <- [:http1, :http2] do
    describe "over #{protocol}" do
      @protocol protocol

      test "pings while the answer arrives in time" do
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
            {EventSourcingDB.ping(client, timeout: @timeout), mailbox()}
          end)

        assert result == {:ok, {:ok, []}}
      end

      test "fails to ping once the timeout ran out, and closes the connection" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client, timeout: @timeout), mailbox()}
          end)

        assert {:ok, {{:error, error}, []}} = result

        assert error == %CallTimedOut{
                 message: "Call timed out: the call did not finish within 400 milliseconds."
               }

        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "fails to ping as a stalled connection if the stall timeout runs out first" do
        client =
          start_server(fn _connection -> :ok end, protocol: @protocol, stall_timeout: @timeout)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client, timeout: 4 * @timeout), mailbox()}
          end)

        assert {:ok, {{:error, %ConnectionStalled{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < 2 * @timeout
      end

      test "fails to open a stream without heartbeats once the timeout ran out, before the response arrives" do
        client = start_server(fn _connection -> :ok end, protocol: @protocol)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            subjects =
              EventSourcingDB.read_subjects(
                client,
                "/",
                %ReadSubjectsOptions{recursive: true},
                timeout: @timeout
              )

            {subjects, mailbox()}
          end)

        assert {:ok, {{:error, %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "fails to ping once the timeout ran out while the body of the answer stalls" do
        client =
          start_server(
            fn connection -> StreamServer.send_head(connection, 200, @json_headers) end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.ping(client, timeout: @timeout), mailbox()}
          end)

        assert {:ok, {{:error, %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "fails to open a stream once the timeout ran out while the body of an error answer stalls" do
        client =
          start_server(
            fn connection -> StreamServer.send_head(connection, 500, @json_headers) end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            subjects =
              EventSourcingDB.read_subjects(
                client,
                "/",
                %ReadSubjectsOptions{recursive: true},
                timeout: @timeout
              )

            {subjects, mailbox()}
          end)

        assert {:ok, {{:error, %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "ends a stream without heartbeats once the timeout ran out, after the items that arrived" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection)
              send_line(connection, %{"type" => "subject", "payload" => %{"subject" => "/books"}})
            end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            subjects =
              EventSourcingDB.read_subjects!(
                client,
                "/",
                %ReadSubjectsOptions{recursive: true},
                timeout: @timeout
              )

            {read(subjects), mailbox()}
          end)

        assert {:ok, {{["/books"], %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end

      test "ends observing events once the timeout ran out, while heartbeats arrive" do
        client =
          start_server(
            fn connection ->
              StreamServer.send_head(connection)
              send_heartbeats(connection, %{"type" => "heartbeat", "payload" => %{}})
            end,
            protocol: @protocol
          )

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            events = EventSourcingDB.observe_events!(client, "/test", timeout: @timeout)
            {read(events), mailbox()}
          end)

        assert {:ok, {{[], %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end
    end
  end

  test "ends a stream once the timeout ran out, even while its lines arrive faster than it is read" do
    client =
      start_server(fn connection ->
        StreamServer.send_head(connection)

        for row <- 1..100 do
          send_line(connection, %{"type" => "row", "payload" => row})
        end
      end)

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        rows =
          client
          |> EventSourcingDB.run_eventql_query!("FROM e IN events PROJECT INTO 1",
            timeout: @timeout
          )
          |> Stream.each(fn _row -> Process.sleep(@interval) end)

        read(rows)
      end)

    assert {:ok, {rows, %CallTimedOut{}}} = result
    assert length(rows) < 10
    assert elapsed >= @timeout
    assert elapsed < @timeout + 300
  end

  for api <- [:v1, :v2] do
    describe "writing events through the #{api} API" do
      @api api

      test "fails with the timeout itself if the request had no connection by then" do
        client = client_without_connection(@api)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.write_events(client, [candidate()], timeout: @timeout), mailbox()}
          end)

        assert {:ok, {{:error, %CallTimedOut{}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
      end

      test "fails with an unknown outcome if the request had a connection by then" do
        client = start_server(fn _connection -> :ok end, api: @api)

        {result, elapsed} =
          StreamServer.run_with_guard(fn ->
            {EventSourcingDB.write_events(client, [candidate()], timeout: @timeout), mailbox()}
          end)

        assert {:ok, {{:error, %OutcomeUnknown{cause: %CallTimedOut{}}}, []}} = result
        assert elapsed >= @timeout
        assert elapsed < @timeout + 300
        assert_receive {:stream_server, :closed}, 1_000
      end
    end

    describe "registering an event schema through the #{api} API" do
      @api api

      test "fails with the timeout itself if the request had no connection by then" do
        client = client_without_connection(@api)

        assert {:error, %CallTimedOut{}} =
                 EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{},
                   timeout: @timeout
                 )
      end

      test "fails with an unknown outcome if the request had a connection by then" do
        client = start_server(fn _connection -> :ok end, api: @api)

        assert {:error, %OutcomeUnknown{cause: %CallTimedOut{}}} =
                 EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{},
                   timeout: @timeout
                 )
      end
    end
  end

  # Over HTTP/2, there is no evidence of a connection, so a write that times
  # out always counts as one that may have been stored.
  for api <- [:v1, :v2] do
    test "fails to write events over HTTP/2 through the #{api} API with an unknown outcome" do
      client = start_server(fn _connection -> :ok end, api: unquote(api), protocol: :http2)

      {result, elapsed} =
        StreamServer.run_with_guard(fn ->
          {EventSourcingDB.write_events(client, [candidate()], timeout: @timeout), mailbox()}
        end)

      assert {:ok, {{:error, %OutcomeUnknown{cause: %CallTimedOut{}}}, []}} = result
      assert elapsed >= @timeout
      assert elapsed < @timeout + 300
    end
  end

  test "fails to write events through the v2 API with an unknown outcome if the timeout runs out while the answer arrives" do
    client =
      start_server(
        fn connection ->
          StreamServer.send_head(connection)
          send_heartbeats(connection, %{"type" => "heartbeat", "data" => %{}})
        end,
        api: :v2
      )

    {result, elapsed} =
      measure(fn -> EventSourcingDB.write_events(client, [candidate()], timeout: @timeout) end)

    assert {:error, %OutcomeUnknown{cause: %CallTimedOut{}}} = result
    assert elapsed >= @timeout
    assert elapsed < @timeout + 300
    assert_receive {:stream_server, :closed}, 1_000
  end

  # Before its first request, a client asks the server for its API, which the
  # timeout bounds as well, so a write that times out while it asks was not
  # sent.
  test "fails to write events with the timeout itself if it runs out while the client asks for the API" do
    base_url = FakeServer.start(fn _request -> :silent end)
    client = Client.new(base_url: base_url, api_token: "secret", req_options: [retry: false])

    {result, elapsed} =
      measure(fn -> EventSourcingDB.write_events(client, [candidate()], timeout: @timeout) end)

    assert {:error, %CallTimedOut{}} = result
    assert elapsed >= @timeout
    assert elapsed < @timeout + 300
  end

  # A call with a timeout asks for the API on its own, so that it does not
  # wait for the answer to another call, and does not hand its timeout on to
  # another call either.
  for first <- [:without_timeout, :with_timeout] do
    @first first

    test "asks for the API on its own if it has a timeout, after a call #{first} began to ask" do
      base_url =
        FakeServer.start(fn
          %{path: "/api/v2/system/ping"} ->
            Process.sleep(3 * @timeout)
            {404, ""}

          %{path: "/api/v1/ping"} ->
            {200, Jason.encode!(@ping_received)}
        end)

      client = Client.new(base_url: base_url, api_token: "secret", req_options: [retry: false])
      options = %{without_timeout: [], with_timeout: [timeout: @timeout]}
      second = if @first == :with_timeout, do: :without_timeout, else: :with_timeout

      first_task =
        Task.async(fn -> measure(fn -> EventSourcingDB.ping(client, options[@first]) end) end)

      assert_receive {:fake_server, :request, %{path: "/api/v2/system/ping"}}, 1_000

      second_task =
        Task.async(fn -> measure(fn -> EventSourcingDB.ping(client, options[second]) end) end)

      results = %{@first => Task.await(first_task), second => Task.await(second_task)}

      assert {{:error, %CallTimedOut{}}, timed_out_after} = results.with_timeout
      assert timed_out_after < 2 * @timeout
      assert {:ok, _elapsed} = results.without_timeout
    end
  end

  test "runs a request with a single answer in a process of its own with the callers and the Logger metadata of the calling process" do
    test_process = self()

    client =
      start_server(
        fn connection ->
          StreamServer.send_head(connection, 200, @json_headers)
          StreamServer.send_data(connection, Jason.encode!(@ping_received))
          StreamServer.send_end(connection)
        end,
        req_options: [plugins: [report_process(test_process)]]
      )

    {result, _elapsed} =
      StreamServer.run_with_guard(fn ->
        # The metadata of the calling process, whose keys a test need not
        # configure for Logger.
        metadata = [request_id: "4711"]
        Logger.metadata(metadata)
        {self(), EventSourcingDB.ping(client, timeout: @timeout), mailbox()}
      end)

    assert {:ok, {caller, :ok, []}} = result
    assert_receive {:process, process, context}
    assert process != caller
    assert [^caller | _callers] = context.callers
    assert context.logger_metadata[:request_id] == "4711"
  end

  test "runs a request with a single answer in the calling process, and lets it stall as before, without a timeout" do
    test_process = self()

    client =
      start_server(fn _connection -> :ok end,
        stall_timeout: @timeout,
        req_options: [plugins: [report_process(test_process)]]
      )

    {result, elapsed} =
      StreamServer.run_with_guard(fn ->
        {self(), EventSourcingDB.ping(client, []), mailbox()}
      end)

    assert {:ok, {caller, {:error, %ConnectionStalled{}}, []}} = result
    assert_receive {:process, ^caller, _context}
    assert elapsed >= @timeout
    assert elapsed < 2 * @timeout
  end

  # Reads the stream until it ends or raises, and returns the items, together
  # with what it raised.
  defp read(stream) do
    test_process = self()
    ref = make_ref()

    raised =
      try do
        Enum.each(stream, &send(test_process, {ref, &1}))
        nil
      rescue
        error -> error
      end

    {received(ref, []), raised}
  end

  defp received(ref, items) do
    receive do
      {^ref, item} -> received(ref, [item | items])
    after
      0 -> Enum.reverse(items)
    end
  end

  # A client of a server that never accepts a connection, so that the
  # handshake of TLS that the client asks for never finishes, and the
  # request never gets its connection.
  defp client_without_connection(api) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen_socket)

    client =
      Client.new(
        base_url: "https://127.0.0.1:#{port}",
        api_token: "secret",
        stall_timeout: @stall_timeout,
        req_options: [retry: false]
      )

    :ok = ApiVersion.remember(client, api)
    on_exit(fn -> ApiVersion.forget(client) end)
    client
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
             %{callers: Process.get(:"$callers"), logger_metadata: Logger.metadata()}}
          )

          request
        end
      )
    end
  end

  # Every client of these tests waits for the server longer than the timeout
  # of the call, unless a test says otherwise.
  defp start_server(script, options \\ []) do
    StreamServer.start(script, Keyword.put_new(options, :stall_timeout, @stall_timeout))
  end

  defp send_line(connection, line) do
    StreamServer.send_line(connection, line)
  end

  # Sends a heartbeat every interval for a second, as long as the client
  # reads them.
  defp send_heartbeats(connection, heartbeat, count \\ 10) do
    with :ok <- send_line(connection, heartbeat), true <- count > 1 do
      Process.sleep(@interval)
      send_heartbeats(connection, heartbeat, count - 1)
    end
  end

  defp measure(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started_at}
  end

  defp candidate() do
    create_test_eventcandidate("/test", %{"value" => 1})
  end

  defp mailbox() do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end
end
