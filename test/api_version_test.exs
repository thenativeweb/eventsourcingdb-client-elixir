defmodule EventSourcingDBTest.ApiVersion do
  alias EventSourcingDB.{
    Client,
    IsEventQLQueryTrue,
    IsSubjectPopulated,
    IsSubjectPristine,
    ManagementEvent,
    PreconditionOptions,
    ReadSubjectsOptions
  }

  alias EventSourcingDB.Errors.{
    ConnectionStalled,
    DbApiError,
    IncompatibleServer,
    InvalidResponseType,
    InvalidServerHeader,
    OutcomeUnknown,
    TransmissionError
  }

  alias EventSourcingDB.Transport.ApiVersion
  alias EventSourcingDBTest.FakeServer
  use ExUnit.Case, async: true

  # How the client finds out whether its server offers the v2 API: with the
  # v2 ping, on its first request.

  @v2_ping Jason.encode!(%{
             "type" => "event",
             "data" => %{
               "specversion" => "1.0",
               "id" => "01a150ce-477b-7636-a58e-d24b5469216c",
               "source" => "https://www.eventsourcingdb.io",
               "type" => "io.eventsourcingdb.api.ping-received",
               "subject" => "/api/v2/system/ping",
               "time" => "2026-10-18T12:00:00.000000000Z",
               "datacontenttype" => "application/json",
               "data" => %{"message" => "My God, it's full of stars."}
             }
           })

  @v1_ping Jason.encode!(%{
             "specversion" => "1.0",
             "id" => "0",
             "source" => "https://www.eventsourcingdb.io",
             "type" => "io.eventsourcingdb.api.ping-received",
             "subject" => "/api/v1/ping",
             "time" => "2026-10-18T12:00:00.000000000Z",
             "datacontenttype" => "application/json",
             "data" => %{"message" => "My God, it's full of stars."}
           })

  test "creating a client makes no request" do
    url = FakeServer.start(fn _request -> {500, ""} end)
    _client = client(url)

    assert received_requests() == []
  end

  test "the first request asks for the v2 ping, and uses the v2 API if the server answers it" do
    url = FakeServer.start(&v2_server/1)
    client = client(url)

    assert EventSourcingDB.verify_api_token(client) == :ok
    assert EventSourcingDB.verify_api_token(client) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"POST", "/api/v2/system/verify-token"},
             {"POST", "/api/v2/system/verify-token"}
           ]
  end

  for status <- [404, 405] do
    @status status

    test "the first request uses the v1 API if the server answers the v2 ping with #{status}" do
      url = FakeServer.start(&v1_server(&1, @status))
      client = client(url)

      assert EventSourcingDB.ping(client) == :ok
      assert EventSourcingDB.ping(client) == :ok

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v1/ping"},
               {"GET", "/api/v1/ping"}
             ]
    end
  end

  for status <- [404, 405] do
    @status status

    test "the first request uses the v1 API if the v2 ping is answered with #{status} by something else than EventSourcingDB" do
      url =
        FakeServer.start(fn
          %{path: "/api/v2/system/ping"} -> {@status, [{"server", "nginx"}], "not found\n"}
          request -> v1_server(request, 404)
        end)

      client = client(url)

      assert EventSourcingDB.ping(client) == :ok
      assert EventSourcingDB.ping(client) == :ok

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v1/ping"},
               {"GET", "/api/v1/ping"}
             ]
    end
  end

  # A proxy in front of a server without the v2 API answers with a page of
  # its own, such as the one nginx sends.
  test "the first request uses the v1 API if a proxy answers the v2 ping with its HTML page for 404" do
    url =
      FakeServer.start(fn
        %{path: "/api/v2/system/ping"} ->
          {404, [{"server", "nginx"}, {"content-type", "text/html"}],
           "<html>\r\n<head><title>404 Not Found</title></head>\r\n<body>\r\n<center><h1>404 Not Found</h1></center>\r\n<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n"}

        request ->
          v1_server(request, 404)
      end)

    client = client(url)

    assert EventSourcingDB.ping(client) == :ok
    assert EventSourcingDB.ping(client) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"},
             {"GET", "/api/v1/ping"}
           ]
  end

  test "the first request fails if the v2 ping is answered with an event by something else than EventSourcingDB, and remembers nothing" do
    url =
      FakeServer.start(fn
        %{path: "/api/v2/system/ping"} -> {200, [{"server", "nginx"}], @v2_ping}
        request -> v2_server(request)
      end)

    client = client(url)

    assert EventSourcingDB.verify_api_token(client) == {:error, %InvalidServerHeader{}}
    assert EventSourcingDB.verify_api_token(client) == {:error, %InvalidServerHeader{}}

    assert received_requests() == [{"GET", "/api/v2/system/ping"}, {"GET", "/api/v2/system/ping"}]
  end

  test "every client of a server shares what was found, however it was created" do
    url = FakeServer.start(&v1_server(&1, 404))

    assert EventSourcingDB.ping(client(url)) == :ok
    assert EventSourcingDB.ping(Client.new(url <> "/", "another token")) == :ok
    assert EventSourcingDB.ping(%Client{base_url: URI.parse(url), api_token: "secret"}) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"},
             {"GET", "/api/v1/ping"},
             {"GET", "/api/v1/ping"}
           ]
  end

  test "a copy of a client with another base URL finds out the API of its own server" do
    v2_url = FakeServer.start(&v2_server/1)
    v1_url = FakeServer.start(&v1_server(&1, 404))
    client = client(v2_url)

    assert EventSourcingDB.verify_api_token(client) == :ok
    assert EventSourcingDB.ping(%{client | base_url: URI.parse(v1_url)}) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"POST", "/api/v2/system/verify-token"},
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"}
           ]
  end

  # A client is a plain value, which a module attribute can hold, and which
  # equals another client of the same options.
  @client Client.new("http://localhost:3000", "secret")

  test "a client is a plain value" do
    assert @client == Client.new("http://localhost:3000", "secret")

    assert Enum.sort(Map.keys(@client) -- [:__struct__]) == [
             :api_token,
             :base_url,
             :req_options,
             :stall_timeout
           ]
  end

  describe "a server that is rolled back to a version without the v2 API" do
    for call <- [:verify_api_token, :read_event_types, :write_events] do
      @call call

      test "fails #{call} once with the 404 of the v2 route, and is asked for its API again on the next request" do
        api = start_supervised!({Agent, fn -> :v2 end}, id: make_ref())

        url =
          FakeServer.start(fn request ->
            case Agent.get(api, & &1) do
              :v2 -> v2_server(request)
              :v1 -> v1_server(request, 404)
            end
          end)

        client = client(url)
        assert :ok = succeed(@call, client)

        Agent.update(api, fn _api -> :v1 end)

        assert {:error, error} = run(@call, client)
        assert %DbApiError{status: 404} = unwrap_outcome(error)
        assert :ok = succeed(@call, client)

        assert Enum.count(received_requests(), &(&1 == {"GET", "/api/v2/system/ping"})) == 2
      end
    end

    # A proxy in front of the server that forwards only the v1 API answers the
    # routes of the v2 API itself, as it answers the probe.
    for call <- [:verify_api_token, :read_event_types, :write_events, :register_event_schema],
        status <- [404, 405] do
      @call call
      @status status

      test "fails #{call} once as before if a proxy answers the v2 route with #{status}, and is asked for its API again on the next request" do
        api = start_supervised!({Agent, fn -> :v2 end}, id: make_ref())

        url =
          FakeServer.start(fn request ->
            case Agent.get(api, & &1) do
              :v2 -> v2_server(request)
              :v1 -> proxied_v1_server(request, @status)
            end
          end)

        client = client(url)
        assert :ok = succeed(@call, client)

        Agent.update(api, fn _api -> :v1 end)

        assert run(@call, client) == {:error, header_error(@call)}
        assert :ok = succeed(@call, client)

        assert Enum.count(received_requests(), &(&1 == {"GET", "/api/v2/system/ping"})) == 2
      end
    end
  end

  # A client remembers that its server does not offer the v2 API, while the
  # server may be upgraded to a version that does. A write that needs the v2
  # API asks again before it fails for the lack of it.
  describe "a server that is upgraded to a version with the v2 API" do
    for options <- [[], [timeout: 5_000]] do
      @options options

      test "is asked for its API again by a write with a recursive precondition, which then goes through the v2 API, as every later request does (options: #{inspect(options)})" do
        api = start_supervised!({Agent, fn -> :v1 end}, id: make_ref())

        url =
          FakeServer.start(fn request ->
            case Agent.get(api, & &1) do
              :v1 -> v1_server(request, 404)
              :v2 -> upgraded_server(request)
            end
          end)

        client = client(url)
        assert EventSourcingDB.verify_api_token(client) == :ok

        Agent.update(api, fn _api -> :v2 end)

        assert EventSourcingDB.verify_api_token(client) == :ok

        assert {:ok, [_event]} =
                 EventSourcingDB.write_events(
                   client,
                   [candidate()],
                   [recursive_precondition()],
                   @options
                 )

        assert EventSourcingDB.verify_api_token(client) == :ok

        requests = received_request_maps()

        assert Enum.map(requests, &{&1.method, &1.path}) == [
                 {"GET", "/api/v2/system/ping"},
                 {"POST", "/api/v1/verify-api-token"},
                 {"POST", "/api/v1/verify-api-token"},
                 {"GET", "/api/v2/system/ping"},
                 {"POST", "/api/v2/data/write-events"},
                 {"POST", "/api/v2/system/verify-token"}
               ]

        write = Enum.find(requests, &(&1.path == "/api/v2/data/write-events"))

        assert Jason.decode!(write.body)["preconditions"] == [
                 %{
                   "type" => "isSubjectPristine",
                   "payload" => %{"subject" => "/test", "options" => %{"recursive" => true}}
                 }
               ]
      end
    end

    test "is asked for its API again by every write with a recursive precondition while it does not offer the v2 API, which then fails without being sent" do
      url = FakeServer.start(&v1_server(&1, 404))
      client = client(url)
      assert EventSourcingDB.verify_api_token(client) == :ok

      for _attempt <- 1..2 do
        assert {:error, %IncompatibleServer{}} =
                 EventSourcingDB.write_events(client, [candidate()], [recursive_precondition()])
      end

      assert EventSourcingDB.verify_api_token(client) == :ok

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/verify-api-token"},
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/verify-api-token"}
             ]
    end

    test "is not asked again by a write whose preconditions the v1 API checks, which keeps using the v1 API" do
      url = FakeServer.start(&v1_server(&1, 404))
      client = client(url)
      assert EventSourcingDB.verify_api_token(client) == :ok

      preconditions = [
        %IsSubjectPristine{subject: "/test", options: PreconditionOptions.new(recursive: false)},
        %IsSubjectPopulated{subject: "/test"},
        %IsEventQLQueryTrue{query: "FROM e IN events PROJECT INTO COUNT() == 0"}
      ]

      assert {:ok, [_event]} = EventSourcingDB.write_events(client, [candidate()], preconditions)

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/verify-api-token"},
               {"POST", "/api/v1/write-events"}
             ]
    end

    test "is asked once for concurrent writes with a recursive precondition, which each go through the v2 API once, while every other request keeps the v1 API meanwhile" do
      test_process = self()
      api = start_supervised!({Agent, fn -> :v1 end}, id: make_ref())

      url =
        FakeServer.start(fn request ->
          case {Agent.get(api, & &1), request} do
            {:v1, request} -> v1_server(request, 404)
            {:held_v2, %{path: "/api/v2/system/ping"}} -> held_answer(request, test_process)
            {:held_v2, request} -> upgraded_server(request)
          end
        end)

      client = client(url)
      assert EventSourcingDB.verify_api_token(client) == :ok

      Agent.update(api, fn _api -> :held_v2 end)

      writes =
        for _ <- 1..5 do
          Task.async(fn ->
            EventSourcingDB.write_events(client, [candidate()], [recursive_precondition()])
          end)
        end

      prober = receive_held_probe()
      await_waiting(client, 4)

      other = Task.async(fn -> EventSourcingDB.verify_api_token(client) end)

      assert Task.yield(other, 5_000) == {:ok, :ok},
             "a request without a recursive precondition waited for the probe"

      send(prober, :release)

      for write <- writes, do: assert({:ok, [_event]} = Task.await(write))

      assert Enum.frequencies(received_requests()) == %{
               {"GET", "/api/v2/system/ping"} => 2,
               {"POST", "/api/v1/verify-api-token"} => 2,
               {"POST", "/api/v2/data/write-events"} => 5
             }
    end

    # A request that joined while the API was unknown takes over the probe of
    # one that asks again and goes down, and finds the v1 API remembered by
    # then, which it takes without probing. The one that waits to ask again
    # must not take that answer, which is the one it asks again about.
    test "is asked again by a write that waits to ask again, even if the request that took over the probe took the remembered answer instead" do
      test_process = self()
      client = Client.new("http://handed-over.invalid", "secret")
      on_exit(fn -> ApiVersion.forget(client) end)

      probe = fn name ->
        fn ->
          send(test_process, {:probed, name, self()})

          receive do
            {:answer, answer} -> answer
          end
        end
      end

      :ok = ApiVersion.remember(client, :v1)

      {first, monitor} =
        spawn_monitor(fn -> ApiVersion.resolve(client, probe.(:first), stale: :v1) end)

      assert_receive {:probed, :first, ^first}, 5_000

      :ok = ApiVersion.forget(client)
      unknown = Task.async(fn -> ApiVersion.resolve(client, probe.(:unknown)) end)
      await_waiting(client, 1)

      :ok = ApiVersion.remember(client, :v1)
      again = Task.async(fn -> ApiVersion.resolve(client, probe.(:again), stale: :v1) end)
      await_waiting(client, 2)

      Process.exit(first, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^first, :killed}

      assert Task.await(unknown) == {:ok, :v1}
      assert_receive {:probed, :again, prober}, 5_000
      send(prober, {:answer, {:ok, :v2}})

      assert Task.await(again) == {:ok, :v2}
      refute_received {:probed, :unknown, _prober}
    end
  end

  describe "a probe that fails" do
    test "fails the request with the error of the server, remembers nothing, and is made again on the next request" do
      answers = start_answers([{503, "server is shutting down\n"}, {404, "404 page not found\n"}])
      url = FakeServer.start(&v1_server(&1, answers))
      client = client(url)

      assert EventSourcingDB.write_events(client, [candidate()]) ==
               {:error, %DbApiError{status: 503, description: "server is shutting down\n"}}

      assert {:ok, [_event]} = EventSourcingDB.write_events(client, [candidate()])

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/write-events"}
             ]
    end

    test "fails the request if the connection breaks, and is made again on the next request" do
      answers = start_answers([:close, 404])
      url = FakeServer.start(&v1_server(&1, answers))
      client = client(url)

      assert {:error, %TransmissionError{}} = EventSourcingDB.write_events(client, [candidate()])
      assert {:ok, [_event]} = EventSourcingDB.write_events(client, [candidate()])

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/write-events"}
             ]
    end

    test "fails the request if the connection stalls, and is made again on the next request" do
      answers = start_answers([:silent, 404])
      url = FakeServer.start(&v1_server(&1, answers))
      client = client(url, stall_timeout: 300)

      assert {:error, %ConnectionStalled{}} = EventSourcingDB.write_events(client, [candidate()])
      assert {:ok, [_event]} = EventSourcingDB.write_events(client, [candidate()])

      assert received_requests() == [
               {"GET", "/api/v2/system/ping"},
               {"GET", "/api/v2/system/ping"},
               {"POST", "/api/v1/write-events"}
             ]
    end

    test "fails the request if the server answers the v2 ping with something else than an event" do
      url = FakeServer.start(fn _request -> {200, ~s({"type":"heartbeat","data":{}})} end)

      assert EventSourcingDB.ping(client(url)) ==
               {:error, %InvalidResponseType{expected: "event", actual: "heartbeat"}}
    end

    test "fails the request if the server answers the v2 ping with something that is not JSON" do
      url = FakeServer.start(fn _request -> {200, "<html></html>"} end)

      assert {:error, %TransmissionError{reason: %Jason.DecodeError{}}} =
               EventSourcingDB.ping(client(url))
    end

    test "is not retried before a write, which Req never retries" do
      url = FakeServer.start(fn _request -> {503, "unavailable\n"} end)

      assert {:error, %DbApiError{status: 503}} =
               EventSourcingDB.write_events(client(url), [candidate()])

      assert received_requests() == [{"GET", "/api/v2/system/ping"}]
    end
  end

  # Every call of the client SDK but the ping.
  @other_calls [
    :verify_api_token,
    :write_events,
    :read_events,
    :observe_events,
    :run_eventql_query,
    :register_event_schema,
    :read_subjects,
    :read_event_type,
    :read_event_types
  ]

  # The client SDK sends the API token only where it is needed, so neither
  # with the probe nor with the ping, which EventSourcingDB answers without
  # one.
  describe "the API token" do
    test "is sent neither with the probe nor with the ping of a server with the v2 API" do
      url = FakeServer.start(&v2_server/1)

      assert EventSourcingDB.ping(client(url)) == :ok

      assert received_authorizations() == [
               {"GET", "/api/v2/system/ping", nil},
               {"GET", "/api/v2/system/ping", nil}
             ]
    end

    test "is sent neither with the probe nor with the ping of a server without the v2 API" do
      url = FakeServer.start(&v1_server(&1, 404))

      assert EventSourcingDB.ping(client(url)) == :ok

      assert received_authorizations() == [
               {"GET", "/api/v2/system/ping", nil},
               {"GET", "/api/v1/ping", nil}
             ]
    end

    for api <- [:v2, :v1] do
      @api api

      test "is sent with every other call over the #{api} API" do
        # Only the requests matter, so every call but the probe is refused.
        url =
          FakeServer.start(fn
            %{path: "/api/v2/system/ping"} = request -> server(@api, request)
            _request -> {400, "bad request\n"}
          end)

        client = client(url)
        for call <- @other_calls, do: assert({:error, _reason} = run(call, client))

        assert [{"GET", "/api/v2/system/ping", nil} | requests] = received_authorizations()
        assert length(requests) == length(@other_calls)
        assert Enum.reject(requests, &match?({_method, _path, "Bearer secret"}, &1)) == []
      end
    end
  end

  describe "concurrent first requests" do
    test "share a single probe and its result" do
      test_process = self()
      url = FakeServer.start(&held_v1_server(&1, test_process))
      client = client(url)

      tasks = for _ <- 1..5, do: Task.async(fn -> EventSourcingDB.ping(client) end)

      prober = receive_held_probe()
      await_waiting(client, 4)
      send(prober, :release)

      assert Enum.map(tasks, &Task.await/1) == List.duplicate(:ok, 5)

      assert Enum.frequencies(received_requests()) == %{
               {"GET", "/api/v2/system/ping"} => 1,
               {"GET", "/api/v1/ping"} => 5
             }
    end

    test "share the failure of a single probe" do
      test_process = self()

      url =
        FakeServer.start(&held_v1_server(&1, test_process, {500, "internal server error\n"}))

      client = client(url)

      tasks =
        for _ <- 1..5, do: Task.async(fn -> EventSourcingDB.read_event_type(client, "io.x") end)

      prober = receive_held_probe()
      await_waiting(client, 4)
      send(prober, :release)

      assert Enum.map(tasks, &Task.await/1) ==
               List.duplicate(
                 {:error, %DbApiError{status: 500, description: "internal server error\n"}},
                 5
               )

      assert received_requests() == [{"GET", "/api/v2/system/ping"}]
    end

    test "let the next request probe if the one that probes goes down" do
      test_process = self()
      url = FakeServer.start(&held_v1_server(&1, test_process))
      client = client(url)

      {first, monitor} = spawn_monitor(fn -> EventSourcingDB.ping(client) end)
      first_probe = receive_held_probe()

      second = Task.async(fn -> EventSourcingDB.ping(client) end)
      await_waiting(client, 1)

      Process.exit(first, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^first, :killed}

      second_probe = receive_held_probe()
      send(second_probe, :release)
      send(first_probe, :release)

      assert Task.await(second) == :ok
    end
  end

  defp run(:verify_api_token, client), do: EventSourcingDB.verify_api_token(client)
  defp run(:read_event_types, client), do: EventSourcingDB.read_event_types(client)
  defp run(:write_events, client), do: EventSourcingDB.write_events(client, [candidate()])
  defp run(:read_events, client), do: EventSourcingDB.read_events(client, "/test")
  defp run(:observe_events, client), do: EventSourcingDB.observe_events(client, "/test")

  defp run(:run_eventql_query, client),
    do: EventSourcingDB.run_eventql_query(client, "FROM e IN events PROJECT INTO e")

  defp run(:register_event_schema, client) do
    EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{"type" => "object"})
  end

  defp run(:read_subjects, client),
    do: EventSourcingDB.read_subjects(client, "/", %ReadSubjectsOptions{recursive: true})

  defp run(:read_event_type, client),
    do: EventSourcingDB.read_event_type(client, "io.eventsourcingdb.test")

  # Runs the call, and reads a stream that it returns to its end.
  defp succeed(call, client) do
    case run(call, client) do
      :ok -> :ok
      {:ok, %ManagementEvent{}} -> :ok
      {:ok, items} -> if is_list(Enum.to_list(items)), do: :ok
      error -> error
    end
  end

  defp unwrap_outcome(%OutcomeUnknown{cause: cause}), do: cause
  defp unwrap_outcome(error), do: error

  # An answer that does not come from EventSourcingDB fails the call, and
  # leaves the outcome of a write open.
  defp header_error(call) when call in [:write_events, :register_event_schema],
    do: %OutcomeUnknown{cause: %InvalidServerHeader{}}

  defp header_error(_call), do: %InvalidServerHeader{}

  defp server(:v2, request), do: v2_server(request)
  defp server(:v1, request), do: v1_server(request, 404)

  # Answers the v2 ping as EventSourcingDB 1.3 does, and every other request
  # successfully.
  defp v2_server(%{path: "/api/v2/system/ping"}),
    do: {200, [{"content-type", "application/json"}], @v2_ping}

  defp v2_server(%{path: "/api/v2/system/verify-token"}) do
    {200, [{"content-type", "application/json"}],
     String.replace(@v2_ping, "ping-received", "token-verified")}
  end

  defp v2_server(%{path: "/api/v2/data/read-event-types"}) do
    {:lines, [%{"type" => "end", "data" => %{}}]}
  end

  defp v2_server(%{path: "/api/v2/data/write-events"}) do
    {:lines,
     [
       %{"type" => "event", "data" => Jason.decode!(written_event())},
       %{"type" => "end", "data" => %{}}
     ]}
  end

  defp v2_server(%{path: "/api/v2/data/register-event-schema"}) do
    {:lines,
     [
       %{"type" => "event", "data" => schema_registered("/api/v2/data/register-event-schema")},
       %{"type" => "end", "data" => %{}}
     ]}
  end

  # Answers the v2 ping with the given status, or with the next of the given
  # answers, and every other request as EventSourcingDB 1.2 does.
  defp v1_server(%{path: "/api/v2/system/ping"}, answers) when is_pid(answers) do
    case Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end) do
      status when is_integer(status) -> {status, "404 page not found\n"}
      answer -> answer
    end
  end

  defp v1_server(%{path: "/api/v2/system/ping"}, status), do: {status, "404 page not found\n"}

  defp v1_server(%{path: "/api/v1/ping"}, _answers),
    do: {200, [{"content-type", "application/json"}], @v1_ping}

  defp v1_server(%{path: "/api/v1/write-events"}, _answers) do
    {200, [{"content-type", "application/json"}], "[" <> written_event() <> "]"}
  end

  defp v1_server(%{path: "/api/v1/read-event-types"}, _answers) do
    {200, [{"content-type", "application/x-ndjson"}], ""}
  end

  defp v1_server(%{path: "/api/v1/verify-api-token"}, _answers) do
    {200, [{"content-type", "application/json"}],
     String.replace(@v1_ping, "ping-received", "api-token-verified")}
  end

  defp v1_server(%{path: "/api/v1/register-event-schema"}, _answers) do
    {200, [{"content-type", "application/json"}],
     Jason.encode!(schema_registered("/api/v1/register-event-schema"))}
  end

  # A server without the v2 API answers its routes with 404.
  defp v1_server(%{path: "/api/v2/" <> _route}, _answers), do: {404, "404 page not found\n"}

  # Answers as EventSourcingDB 1.3 does, which offers the v1 API next to the
  # v2 API.
  defp upgraded_server(%{path: "/api/v2/" <> _route} = request), do: v2_server(request)
  defp upgraded_server(request), do: v1_server(request, 404)

  # Holds the request until the test releases it, and then answers it as
  # EventSourcingDB 1.3 does.
  defp held_answer(request, test_process) do
    send(test_process, {:held_probe, self()})

    receive do
      :release -> upgraded_server(request)
    end
  end

  # Answers every route of the v2 API with the given status, as a proxy that
  # forwards only the v1 API to a server without the v2 API does, and every
  # other request as that server does.
  defp proxied_v1_server(%{path: "/api/v2/" <> _route}, status),
    do: {status, [{"server", "nginx"}], "not found\n"}

  defp proxied_v1_server(request, _status), do: v1_server(request, 404)

  defp schema_registered(subject) do
    %{
      "specversion" => "1.0",
      "id" => "0",
      "source" => "https://www.eventsourcingdb.io",
      "subject" => subject,
      "type" => "io.eventsourcingdb.api.event-schema-registered",
      "time" => "2026-10-18T12:00:00.000000000Z",
      "datacontenttype" => "application/json",
      "data" => %{"type" => "io.eventsourcingdb.test", "schema" => %{"type" => "object"}}
    }
  end

  defp written_event() do
    Jason.encode!(%{
      "specversion" => "1.0",
      "id" => "0",
      "source" => "https://www.eventsourcingdb.io",
      "subject" => "/test",
      "type" => "io.eventsourcingdb.test",
      "time" => "2026-10-18T12:00:00.000000000Z",
      "datacontenttype" => "application/json",
      "predecessorhash" => String.duplicate("0", 64),
      "data" => %{"value" => 1},
      "hash" => String.duplicate("0", 64)
    })
  end

  # Holds the v2 ping until the test releases it, and then answers it as
  # EventSourcingDB 1.2 does, or with the given answer.
  defp held_v1_server(request, test_process, answer \\ {404, "404 page not found\n"})

  defp held_v1_server(%{path: "/api/v2/system/ping"}, test_process, answer) do
    send(test_process, {:held_probe, self()})

    receive do
      :release -> answer
    end
  end

  defp held_v1_server(request, _test_process, _answer), do: v1_server(request, 404)

  defp receive_held_probe() do
    assert_receive {:held_probe, connection}, 5_000
    connection
  end

  # Waits until the given number of requests waits for the probe that runs,
  # by asking the process that keeps track of the probes, without sleeping.
  defp await_waiting(%Client{base_url: base_url} = client, count) do
    server = base_url |> to_string() |> String.trim_trailing("/")

    waiting =
      case :sys.get_state(ApiVersion) do
        %{^server => probe} -> length(probe.waiting)
        _none -> 0
      end

    if waiting < count, do: await_waiting(client, count), else: :ok
  end

  defp start_answers(answers) do
    start_supervised!({Agent, fn -> answers end})
  end

  defp received_requests(requests \\ []) do
    receive do
      {:fake_server, :request, %{method: method, path: path}} ->
        received_requests([{method, path} | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end

  defp received_request_maps(requests \\ []) do
    receive do
      {:fake_server, :request, request} -> received_request_maps([request | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end

  # The method and the path of every request, together with its Authorization
  # header, or nil without one.
  defp received_authorizations(requests \\ []) do
    receive do
      {:fake_server, :request, %{method: method, path: path, headers: headers}} ->
        received_authorizations([{method, path, headers["authorization"]} | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end

  defp client(url, options \\ []) do
    Client.new([base_url: url, api_token: "secret"] ++ options)
  end

  defp candidate() do
    EventSourcingDBTest.Utils.create_test_eventcandidate("/test", %{"value" => 1})
  end

  defp recursive_precondition() do
    %IsSubjectPristine{subject: "/test", options: PreconditionOptions.new(recursive: true)}
  end
end
