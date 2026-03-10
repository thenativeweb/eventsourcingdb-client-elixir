defmodule EventSourcingDBTest.ObserveEvents do
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "observe existing events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written = EventSourcingDB.write_events!(client, [event_candidate])
    event = EventSourcingDB.observe_events!(client, "/test") |> Enum.at(0)

    assert [event] == written
  end

  test "keep observing events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_stream = EventSourcingDB.observe_events!(client, "/test")

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    written = EventSourcingDB.write_events!(client, [event_candidate])

    event = event_stream |> Enum.at(0)

    assert [event] == written
  end
end
