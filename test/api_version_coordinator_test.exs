defmodule EventSourcingDBTest.ApiVersionCoordinator do
  alias EventSourcingDB.Client
  alias EventSourcingDB.Transport.ApiVersion
  alias EventSourcingDBTest.FakeServer

  # These tests stop the process that keeps track of the probes, which every
  # client shares, so they do not run concurrently with others.
  use ExUnit.Case, async: false

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

  test "first requests that wait for a probe probe on their own if the process that keeps track of the probes goes down" do
    test_process = self()
    url = FakeServer.start(&held_v1_server(&1, test_process))
    client = Client.new(url, "secret")

    tasks = for _ <- 1..3, do: Task.async(fn -> EventSourcingDB.ping(client) end)

    first_probe = receive_held_probe()
    await_waiting(url, 2)

    coordinator = Process.whereis(ApiVersion)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}

    other_probes = for _ <- 1..2, do: receive_held_probe()
    Enum.each([first_probe | other_probes], &send(&1, :release))

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok, :ok]
    await_restart(coordinator)
  end

  defp held_v1_server(%{path: "/api/v2/system/ping"}, test_process) do
    send(test_process, {:held_probe, self()})

    receive do
      :release -> {404, "404 page not found\n"}
    end
  end

  defp held_v1_server(%{path: "/api/v1/ping"}, _test_process) do
    {200, [{"content-type", "application/json"}], @v1_ping}
  end

  defp receive_held_probe() do
    assert_receive {:held_probe, connection}, 5_000
    connection
  end

  # Waits until the given number of requests waits for the probe that runs,
  # by asking the process that keeps track of the probes, without sleeping.
  defp await_waiting(url, count) do
    waiting =
      case :sys.get_state(ApiVersion) do
        %{^url => probe} -> length(probe.waiting)
        _none -> 0
      end

    if waiting < count, do: await_waiting(url, count), else: :ok
  end

  # The supervisor of the application restarts the process, which later tests
  # rely on.
  defp await_restart(old) do
    case Process.whereis(ApiVersion) do
      pid when is_pid(pid) and pid != old -> :sys.get_state(pid)
      _other -> await_restart(old)
    end
  end
end
