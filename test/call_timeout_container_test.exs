defmodule EventSourcingDBTest.CallTimeoutContainer do
  alias EventSourcingDB.Errors.CallTimedOut
  alias EventSourcingDB.Event
  alias EventSourcingDB.ReadEventsOptions
  alias EventSourcingDB.TestContainer
  use ExUnit.Case

  import EventSourcingDBTest.Utils

  # A call with a timeout runs its requests through a process of its own, so
  # these tests check it against EventSourcingDB itself, through the API that
  # the image offers.

  @moduletag timeout: container_test_timeout()

  setup do: start_container()

  test "writes and reads events with a timeout that does not run out", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    candidate = create_test_eventcandidate("/test", %{"value" => 1})

    assert {:ok, [written]} = EventSourcingDB.write_events(client, [candidate], timeout: 10_000)

    assert {:ok, events} =
             EventSourcingDB.read_events(
               client,
               "/test",
               %ReadEventsOptions{recursive: false},
               timeout: 10_000
             )

    assert Enum.map(events, & &1.id) == [written.id]
  end

  test "ends observing events once the timeout ran out, after the events that arrived", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)
    candidate = create_test_eventcandidate("/test", %{"value" => 1})
    {:ok, [%Event{id: id}]} = EventSourcingDB.write_events(client, [candidate])

    test_process = self()
    started_at = System.monotonic_time(:millisecond)
    events = EventSourcingDB.observe_events!(client, "/test", timeout: 1_500)

    assert_raise CallTimedOut,
                 "Call timed out: the call did not finish within 1500 milliseconds.",
                 fn ->
                   Enum.each(events, &send(test_process, {:observed, &1}))
                 end

    assert System.monotonic_time(:millisecond) - started_at >= 1_500
    assert_received {:observed, %Event{id: ^id}}
  end
end
