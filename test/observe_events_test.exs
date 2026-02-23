defmodule EventsourcingdbTest.ObserveEvents do
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "observe existing events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written = Eventsourcingdb.write_events!(client, [event_candidate])
    event = Eventsourcingdb.observe_events!(client, "/test") |> Enum.at(0)

    assert [event] == written
  end

  test "keep observing events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_stream = Eventsourcingdb.observe_events!(client, "/test")

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    written = Eventsourcingdb.write_events!(client, [event_candidate])

    event = event_stream |> Enum.at(0)

    assert [event] == written
  end
end
