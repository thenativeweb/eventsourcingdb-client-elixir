defmodule EventSourcingDBTest.TestContainerWait do
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.TestContainer.Start
  alias EventSourcingDBTest.FakeServer
  alias Testcontainers.{Container, ContainerBuilder, WaitStrategy}
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils

  @v2_ping "/api/v2/system/ping"
  @v1_ping "/api/v1/ping"

  # Testcontainers waits for the database itself when it starts the
  # container, as the container macro of Testcontainers.ExUnit does, whether
  # the server offers the v2 API or not.
  @tag timeout: container_test_timeout()
  test "starts the container through Testcontainers once the database answers its ping" do
    {:ok, esdb} = Testcontainers.start_container(test_container())
    on_exit(fn -> Testcontainers.stop_container(esdb.container_id) end)

    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end

  # EventSourcingDB takes a while to start when Docker is busy, so the test
  # container finds it ready whenever it answers its ping within 10 seconds.
  # The test runs the wait of the test container against a local server that
  # begins to listen only after some seconds, as such a server does.
  for ready_after <- [2_500, 9_000] do
    @ready_after ready_after

    test "finds EventSourcingDB ready that answers its ping after #{ready_after} milliseconds" do
      port = free_port()
      start_supervised!({Task, fn -> listen_later(port, @ready_after) end})

      assert wait(:testcontainers, port) == :ok
    end
  end

  # Both waits, the one with which Testcontainers starts the container
  # itself, and start/1, ask the same in each attempt.
  for {wait, waiter} <- [{:testcontainers, "Testcontainers"}, {:start, "start/1"}] do
    @wait wait

    for status <- [404, 405] do
      @status status

      test "finds the database ready once the v1 ping answers with 200, after the v2 ping " <>
             "answered with #{status}, when #{waiter} waits" do
        port = serve(%{@v2_ping => [@status], @v1_ping => [200]})

        assert wait(@wait, port) == :ok
        assert pings() == [@v2_ping, @v1_ping]
      end
    end

    test "finds the database ready once the v2 ping answers with 200, without asking for the " <>
           "v1 ping, when #{waiter} waits" do
      port = serve(%{@v2_ping => [200], @v1_ping => [200]})

      assert wait(@wait, port) == :ok
      assert pings() == [@v2_ping]
    end

    test "finds the database ready without the v1 API once the v2 ping answers with 200, " <>
           "when #{waiter} waits" do
      port = serve(%{@v2_ping => [200], @v1_ping => [404]})

      assert wait(@wait, port) == :ok
      assert pings() == [@v2_ping]
    end

    test "tries again after the v2 ping answered with another status, without asking for the " <>
           "v1 ping, when #{waiter} waits" do
      port = serve(%{@v2_ping => [503, 200], @v1_ping => [200]})

      assert wait(@wait, port) == :ok
      assert pings() == [@v2_ping, @v2_ping]
    end

    test "tries again with the v2 ping after the v1 ping answered with another status than 200, " <>
           "when #{waiter} waits" do
      port = serve(%{@v2_ping => [404, 200], @v1_ping => [503]})

      assert wait(@wait, port) == :ok
      assert pings() == [@v2_ping, @v1_ping, @v2_ping]
    end
  end

  test "tries again after the v2 ping ran out of time, without asking for the v1 ping, " <>
         "when start/1 waits" do
    port = serve(%{@v2_ping => [:silent, 200], @v1_ping => [200]})

    assert wait(:start, port) == :ok
    assert pings() == [@v2_ping, @v2_ping]
  end

  # Testcontainers gives each request whatever is left of its wait, so a v2
  # ping that runs out of time ends the wait.
  test "gives up once the v2 ping ran out of time, without asking for the v1 ping, " <>
         "when Testcontainers waits" do
    port = serve(%{@v2_ping => [:silent], @v1_ping => [200]})
    %Container{wait_strategies: [wait_strategy]} = ContainerBuilder.build(TestContainer.new())

    started_at = System.monotonic_time(:millisecond)
    result = wait(:testcontainers, port)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert {:error, :timeout, _wait_strategy} = result
    assert pings() == [@v2_ping]
    assert elapsed >= wait_strategy.timeout
    assert elapsed < wait_strategy.timeout + 5_000
  end

  # Waits for the database behind the given port as Testcontainers does, when
  # it starts the container itself, or as start/1 does, whose container is
  # left out, so that only its wait remains.
  defp wait(:testcontainers, port) do
    %Container{wait_strategies: [wait_strategy]} = ContainerBuilder.build(TestContainer.new())

    container = %Container{
      image: "thenativeweb/eventsourcingdb",
      exposed_ports: [{3000, port}]
    }

    WaitStrategy.wait_until_container_is_ready(wait_strategy, container, nil)
  end

  defp wait(:start, port) do
    config = TestContainer.with_startup_timeout(TestContainer.new(), 5_000)

    start_container = fn container, _start ->
      {:ok, %{container | container_id: "not-a-container"}}
    end

    inspect_container = fn _container_id, _inspect -> {:ok, {"running", port}} end
    remove_containers = fn _attempt_id, _remove -> :ok end

    case Start.run(config,
           start_container: start_container,
           inspect_container: inspect_container,
           remove_containers: remove_containers
         ) do
      {:ok, _container} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Answers each path with the next of the given answers, a status or
  # :silent, which never answers, and with the last one again once they run
  # out, and every other path with 404. Returns the port it listens on.
  defp serve(answers) do
    remaining = start_supervised!({Agent, fn -> answers end})

    url =
      FakeServer.start(fn %{path: path} ->
        answer =
          Agent.get_and_update(remaining, fn answers ->
            case Map.get(answers, path, [404]) do
              [answer] -> {answer, answers}
              [answer | rest] -> {answer, Map.put(answers, path, rest)}
            end
          end)

        case answer do
          :silent -> :silent
          status -> {status, ""}
        end
      end)

    URI.parse(url).port
  end

  # The paths that the server received so far, in order.
  defp pings(paths \\ []) do
    receive do
      {:fake_server, :request, %{path: path}} -> pings(paths ++ [path])
    after
      0 -> paths
    end
  end

  defp free_port() do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Refuses every connection until it listens, and then answers every request
  # as EventSourcingDB answers its ping.
  defp listen_later(port, delay) do
    Process.sleep(delay)
    {:ok, listen_socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    answer(listen_socket)
  end

  defp answer(listen_socket) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, _request} = :gen_tcp.recv(socket, 0)
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
    :gen_tcp.close(socket)
    answer(listen_socket)
  end
end
