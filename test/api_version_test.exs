defmodule EventSourcingDBTest.ApiVersion do
  alias EventSourcingDB.Client

  alias EventSourcingDB.Errors.{
    ConnectionStalled,
    DbApiError,
    InvalidResponseType,
    InvalidServerHeader,
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

  test "copies of a client share what it found" do
    url = FakeServer.start(&v1_server(&1, 404))
    client = client(url)

    assert EventSourcingDB.ping(client) == :ok
    assert EventSourcingDB.ping(%{client | req_options: [receive_timeout: 5_000]}) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"},
             {"GET", "/api/v1/ping"}
           ]
  end

  test "a client that was not created with new asks for every request" do
    url = FakeServer.start(&v1_server(&1, 404))
    client = %Client{base_url: URI.parse(url), api_token: "secret"}

    assert EventSourcingDB.ping(client) == :ok
    assert EventSourcingDB.ping(client) == :ok

    assert received_requests() == [
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"},
             {"GET", "/api/v2/system/ping"},
             {"GET", "/api/v1/ping"}
           ]
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

  # Answers the v2 ping as EventSourcingDB 1.3 does, and every other request
  # successfully.
  defp v2_server(%{path: "/api/v2/system/ping"}),
    do: {200, [{"content-type", "application/json"}], @v2_ping}

  defp v2_server(%{path: "/api/v2/system/verify-token"}) do
    {200, [{"content-type", "application/json"}],
     String.replace(@v2_ping, "ping-received", "token-verified")}
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
    {200, [{"content-type", "application/json"}],
     Jason.encode!([
       %{
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
       }
     ])}
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
  defp await_waiting(%Client{__api_version__: cache} = client, count) do
    waiting =
      case :sys.get_state(ApiVersion) do
        %{^cache => probe} -> length(probe.waiting)
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

  defp client(url, options \\ []) do
    Client.new([base_url: url, api_token: "secret"] ++ options)
  end

  defp candidate() do
    EventSourcingDBTest.Utils.create_test_eventcandidate("/test", %{"value" => 1})
  end
end
