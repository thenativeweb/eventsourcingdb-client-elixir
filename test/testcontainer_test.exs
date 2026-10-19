defmodule EventSourcingDBTest.TestContainer do
  alias DockerEngineAPI.Api.Container, as: DockerContainer
  alias DockerEngineAPI.Model.ErrorResponse
  alias EventSourcingDB.Errors.ContainerStartFailed
  alias EventSourcingDB.Event
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.TestContainer.Start
  use ExUnit.Case

  import EventSourcingDBTest.Utils

  # The tests start containers that are meant to fail, and check that none of
  # them is left, so they run one after the other, and not at the same time as
  # the tests of other modules.

  @start_label "io.eventsourcingdb.container-start"

  test "starts with a custom port" do
    %{esdb: esdb} = start_container(TestContainer.with_port(test_container(), 4000))

    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
    assert esdb.labels[@start_label] =~ ~r/^[0-9a-f]{32}$/
  end

  test "waits for 30 seconds by default" do
    assert TestContainer.new().startup_timeout == 30_000
  end

  test "waits for the startup timeout that is set" do
    assert TestContainer.with_startup_timeout(TestContainer.new(), 1_500).startup_timeout == 1_500
  end

  test "requires a startup timeout of a positive integer of milliseconds" do
    for startup_timeout <- [0, -1_000, 1.5, "30000", nil] do
      assert_raise FunctionClauseError, fn ->
        TestContainer.with_startup_timeout(TestContainer.new(), startup_timeout)
      end
    end
  end

  test "does not count the time before Docker creates the container, such as pulling the image" do
    attempts = record_attempts()
    startup_timeout = 500

    # Takes three times the startup timeout before Docker would create the
    # container, and then ends the attempt.
    start_container = fn container, _start ->
      record(attempts, container)
      Process.sleep(3 * startup_timeout)
      {:error, :stopped}
    end

    config = TestContainer.with_startup_timeout(test_container(), startup_timeout)

    assert Start.run(config, start_container: start_container) ==
             {:error,
              %ContainerStartFailed{
                message: "failed to start the container: :stopped",
                cause: :stopped
              }}

    assert length(attempt_ids(attempts)) == 1
  end

  test "reads the port of the database anew for each ping, and accepts only 200 OK" do
    # A stale port, on which something else answers with a status of
    # success, but not with 200 OK.
    {stale_port, stale_pings} = start_stale_server()

    # Docker publishes the port only late: the first inspections find none,
    # the next ones the stale port, and only the ones after that the port of
    # the database.
    inspections = :counters.new(1, [])

    inspect_container = fn container_id, inspect ->
      :counters.add(inspections, 1, 1)

      case {:counters.get(inspections, 1), inspect.(container_id)} do
        {count, {:ok, {status, _host_port}}} when count <= 3 -> {:ok, {status, nil}}
        {count, {:ok, {status, _host_port}}} when count <= 6 -> {:ok, {status, stale_port}}
        {_count, inspection} -> inspection
      end
    end

    config = TestContainer.with_startup_timeout(test_container(), 10_000)

    assert {:ok, esdb} = Start.run(config, inspect_container: inspect_container)
    on_exit(fn -> TestContainer.stop(esdb) end)

    assert :counters.get(inspections, 1) > 6
    assert :counters.get(stale_pings, 1) > 0
    assert TestContainer.get_mapped_port(esdb) != stale_port
    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end

  test "replaces a container in which the database does not become reachable" do
    attempts = record_attempts()

    start_container = fn container, start ->
      case record(attempts, container) do
        1 -> start.(without_network(container))
        2 -> start.(listening_elsewhere(container))
        _attempt -> start.(container)
      end
    end

    config =
      test_container()
      |> TestContainer.with_signing_key()
      |> TestContainer.with_startup_timeout(5_000)

    assert {:ok, esdb} = Start.run(config, start_container: start_container)
    on_exit(fn -> TestContainer.stop(esdb) end)

    assert [first, second, third] = attempt_ids(attempts)
    assert Enum.uniq([first, second, third]) == [first, second, third]
    assert_removed([first, second])
    assert esdb.labels[@start_label] == third

    # The container that replaced the others signs events, too, so it got
    # the signing key as well.
    client = TestContainer.get_client(esdb)

    [event] =
      EventSourcingDB.write_events!(client, [
        create_test_eventcandidate("/test", %{"value" => 23})
      ])

    assert Event.verify_signature(event, TestContainer.get_verification_key(esdb)) == :ok
  end

  for {name, startup_timeout, seconds} <- [
        {"as Docker does not publish its port", 2_000, "2"},
        {"as it does not listen on the port that Docker publishes", 1_500, "1.5"},
        {"as Docker does not hand it out in time", 1_000, "1"}
      ] do
    @name name
    @startup_timeout startup_timeout
    @seconds seconds

    test "gives up after 3 containers in which the database does not become reachable, #{name}" do
      attempts = record_attempts()

      # A fourth attempt would work, so that the start does not try forever
      # if it does not stop.
      start_container = fn container, start ->
        case {record(attempts, container), @name} do
          {attempt, _name} when attempt > 3 ->
            start.(container)

          {_attempt, "as Docker does not publish its port"} ->
            start.(without_network(container))

          {_attempt, "as it does not listen on the port that Docker publishes"} ->
            start.(listening_elsewhere(container))

          {_attempt, "as Docker does not hand it out in time"} ->
            started = start.(container)
            Process.sleep(2 * @startup_timeout)
            started
        end
      end

      config = TestContainer.with_startup_timeout(test_container(), @startup_timeout)

      started_at = System.monotonic_time(:millisecond)
      result = Start.run(config, start_container: start_container)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert result ==
               {:error,
                %ContainerStartFailed{
                  message:
                    "failed to start the container, the database did not become reachable " <>
                      "within #{@seconds}s in any of 3 containers"
                }}

      assert [_first, _second, _third] = ids = attempt_ids(attempts)
      assert Enum.uniq(ids) == ids
      assert_removed(ids)

      # Each container got the startup timeout that was set, and not the
      # default.
      assert elapsed >= 3 * @startup_timeout
      assert elapsed < 30_000
    end
  end

  test "fails at once if the container exits, and names the end of its log" do
    attempts = record_attempts()

    start_container = fn container, start ->
      record(attempts, container)
      start.(%{container | cmd: container.cmd ++ ["--does-not-exist"]})
    end

    assert {:error, %ContainerStartFailed{message: message, cause: nil}} =
             Start.run(test_container(), start_container: start_container)

    prefix = "failed to start the container, it exited before the database became reachable: "
    assert String.starts_with?(message, prefix)

    # EventSourcingDB writes its usage along with the error, which is longer
    # than 20 lines.
    log_tail = String.replace_prefix(message, prefix, "")
    assert length(String.split(log_tail, "\n")) == 20
    assert log_tail =~ "--http-port"

    assert [attempt_id] = attempt_ids(attempts)
    assert_removed([attempt_id])
  end

  test "names exactly the last 20 lines of the log of a container that exited" do
    lines = for number <- 1..25, do: "line #{number}"

    # Docker frames what the container writes to its standard output and to
    # its standard error, each with a header of 8 bytes, and the blank lines
    # at the end of the log do not count.
    log =
      (lines ++ ["", ""])
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        payload = line <> "\n"
        <<rem(index, 2) + 1, 0, 0, 0, byte_size(payload)::32, payload::binary>>
      end)
      |> IO.iodata_to_binary()

    assert Start.tail(log) == Enum.join(Enum.drop(lines, 5), "\n")
    assert Start.tail(Enum.join(lines, "\n") <> "\n") == Enum.join(Enum.drop(lines, 5), "\n")
  end

  test "fails at once if Docker fails, with the error of Docker" do
    attempts = record_attempts()

    start_container = fn container, start ->
      record(attempts, container)
      start.(container)
    end

    # Docker rejects the reference on its own, without asking a registry.
    config = TestContainer.with_image_tag(test_container(), "not a valid tag")

    assert Start.run(config, start_container: start_container) ==
             {:error,
              %ContainerStartFailed{
                message: "failed to start the container: {:http_error, 400}",
                cause: {:http_error, 400}
              }}

    assert [attempt_id] = attempt_ids(attempts)
    assert_removed([attempt_id])
  end

  test "names the message of an error that Docker reports" do
    reason = {:failed_to_pull_image, %ErrorResponse{message: "manifest unknown"}}

    assert Start.run(test_container(),
             start_container: fn _container, _start -> {:error, reason} end
           ) ==
             {:error,
              %ContainerStartFailed{
                message: "failed to start the container: manifest unknown",
                cause: reason
              }}
  end

  test "fails at once if Docker fails while it waits for the database" do
    attempts = record_attempts()

    start_container = fn container, start ->
      record(attempts, container)
      start.(container)
    end

    inspect_container = fn _container_id, _inspect -> {:error, :docker_failed} end
    config = TestContainer.with_startup_timeout(test_container(), 10_000)

    started_at = System.monotonic_time(:millisecond)

    result =
      Start.run(config, start_container: start_container, inspect_container: inspect_container)

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert result ==
             {:error,
              %ContainerStartFailed{
                message: "failed to start the container: :docker_failed",
                cause: :docker_failed
              }}

    assert elapsed < 10_000
    assert [attempt_id] = attempt_ids(attempts)
    assert_removed([attempt_id])
  end

  for {name, ending} <- [
        {"while Docker creates it", :creating},
        {"while it waits for the database", :waiting}
      ] do
    @ending ending

    test "removes the container if the caller of the start ends #{name}" do
      attempts = record_attempts()
      test = self()

      start_container = fn container, start ->
        record(attempts, container)

        if @ending == :creating do
          send(test, :creating)
          Process.sleep(500)
        end

        started = start.(container)
        send(test, {:created, started})
        started
      end

      inspect_container = fn container_id, inspect ->
        send(test, :waiting)
        inspect.(container_id)
      end

      caller =
        spawn(fn ->
          Start.run(test_container(),
            start_container: start_container,
            inspect_container: inspect_container
          )
        end)

      assert_receive @ending, 10_000
      Process.exit(caller, :kill)

      assert_receive {:created, {:ok, _container}}, 10_000
      assert [attempt_id] = attempt_ids(attempts)
      assert_removed_soon(attempt_id)
    end
  end

  # Records the id of each attempt of a start, and removes the containers of
  # these attempts once the test is done, whatever happened.
  defp record_attempts do
    {:ok, attempts} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for attempt_id <- Agent.get(attempts, & &1), container_id <- containers(attempt_id) do
        DockerContainer.container_delete(docker(), container_id, force: true)
      end

      Agent.stop(attempts)
    end)

    attempts
  end

  # Records the attempt that starts the container, and returns its number.
  defp record(attempts, container) do
    Agent.get_and_update(attempts, fn attempt_ids ->
      attempt_ids = attempt_ids ++ [container.labels[@start_label]]
      {length(attempt_ids), attempt_ids}
    end)
  end

  defp attempt_ids(attempts), do: Agent.get(attempts, & &1)

  defp assert_removed(attempt_ids) do
    for attempt_id <- attempt_ids do
      assert containers(attempt_id) == [], "a container of the attempt #{attempt_id} is left"
    end
  end

  # The container of an attempt that a caller left behind is removed once
  # Testcontainers is done with it, which takes a moment.
  defp assert_removed_soon(attempt_id, checks \\ 50) do
    cond do
      containers(attempt_id) == [] ->
        :ok

      checks > 0 ->
        Process.sleep(100)
        assert_removed_soon(attempt_id, checks - 1)

      true ->
        flunk("a container of the attempt #{attempt_id} is left")
    end
  end

  defp containers(attempt_id) do
    filters = Jason.encode!(%{"label" => ["#{@start_label}=#{attempt_id}"]})
    {:ok, containers} = DockerContainer.container_list(docker(), all: true, filters: filters)

    Enum.map(containers, & &1."Id")
  end

  defp docker do
    {conn, _docker_host_url, _docker_host} = Testcontainers.Connection.get_connection()
    conn
  end

  # Changes a container, so that it gets no network. Docker then lists the
  # port of the database, but can not publish it, as when Docker Desktop
  # fails to publish it.
  defp without_network(container), do: %{container | network: "none"}

  # Changes a container, so that the database listens on another port than
  # the one that Docker publishes. The container runs, but a ping never
  # reaches the database.
  defp listening_elsewhere(container) do
    index = Enum.find_index(container.cmd, &(&1 == "--http-port"))
    %{container | cmd: List.replace_at(container.cmd, index + 1, "4000")}
  end

  # Answers every request with 204 No Content, and counts the requests.
  defp start_stale_server do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    pings = :counters.new(1, [])

    start_supervised!({Task, fn -> answer(listen_socket, pings) end})

    {port, pings}
  end

  defp answer(listen_socket, pings) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    with {:ok, _request} <- :gen_tcp.recv(socket, 0, 1_000) do
      :counters.add(pings, 1, 1)
      :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n")
    end

    :gen_tcp.close(socket)
    answer(listen_socket, pings)
  end
end
