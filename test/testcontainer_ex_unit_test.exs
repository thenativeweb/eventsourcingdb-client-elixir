defmodule EventSourcingDBTest.TestContainerExUnit do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import EventSourcingDB.TestContainer.ExUnit
  import EventSourcingDBTest.Utils

  @moduletag timeout: container_test_timeout()

  # Checks that the container of a test is gone once the test is done. The
  # callbacks of on_exit run in the reverse order of their registration, so
  # this runs after the container macro stopped the container.
  setup do
    {:ok, started} = Agent.start(fn -> nil end)

    on_exit(fn ->
      attempt_id = Agent.get(started, & &1)
      Agent.stop(started)

      assert attempt_id
      assert containers_of_attempt(attempt_id) == []
    end)

    %{started: started}
  end

  container(:esdb, test_container())

  test "starts a container for the test, and stops it after the test", %{
    esdb: esdb,
    started: started
  } do
    Agent.update(started, fn _ -> esdb.labels["io.eventsourcingdb.container-start"] end)

    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end
end

defmodule EventSourcingDBTest.TestContainerExUnitShared do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import EventSourcingDB.TestContainer.ExUnit
  import EventSourcingDBTest.Utils

  # Checks that the tests share a container, and that it is gone once they
  # are done, which runs after the container macro stopped the container.
  setup_all do
    {:ok, started} = Agent.start(fn -> [] end)

    on_exit(fn ->
      attempt_ids = Agent.get(started, & &1)
      Agent.stop(started)

      assert [attempt_id, attempt_id] = attempt_ids
      assert containers_of_attempt(attempt_id) == []
    end)

    %{started: started}
  end

  container(:esdb, test_container(), shared: true)

  for number <- 1..2 do
    test "starts a container that the tests share, and stops it after them, #{number}",
         %{esdb: esdb, started: started} do
      Agent.update(started, &(&1 ++ [esdb.labels["io.eventsourcingdb.container-start"]]))

      assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
    end
  end
end

defmodule EventSourcingDBTest.TestContainerExUnitFailure do
  alias EventSourcingDB.Errors.ContainerStartFailed
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import EventSourcingDB.TestContainer.ExUnit
  import EventSourcingDBTest.Utils

  @moduletag timeout: container_test_timeout()

  test "raises the error of a start that fails, which uses the startup timeout that is set" do
    # The database never becomes reachable within a millisecond.
    config = TestContainer.with_startup_timeout(test_container(), 1)

    for {options, callback} <- [{[], :setup}, {[shared: true], :setup_all}] do
      macro = quote do: container(:esdb, unquote(Macro.escape(config)), unquote(options))
      assert {^callback, _meta, [[do: run_block]]} = Macro.expand_once(macro, __ENV__)

      assert_raise ContainerStartFailed,
                   "failed to start the container, the database did not become reachable " <>
                     "within 0.001s in any of 3 containers",
                   fn -> Code.eval_quoted(run_block) end
    end
  end
end
