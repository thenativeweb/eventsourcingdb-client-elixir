defmodule EventSourcingDBTest.ObserveEvents do
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.ObserveEventsOptions
  alias EventSourcingDB.BoundOptions
  alias EventSourcingDB.FromLatestEventOptions
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

  test "observes with lower bound", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    first_event = create_test_eventcandidate("/test", %{"value" => 23})
    second_event = create_test_eventcandidate("/test", %{"value" => 42})

    EventSourcingDB.write_events!(client, [first_event, second_event])

    events =
      EventSourcingDB.observe_events!(client, "/", %ObserveEventsOptions{
        recursive: true,
        lower_bound: %BoundOptions{
          id: "1",
          type: :inclusive
        }
      })
      |> Enum.take(1)

    assert length(events) == 1
    assert Enum.at(events, 0).data["value"] == 42
  end

  test "observes from latest event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    first_event =
      create_test_eventcandidate("/test", %{"value" => 23},
        type: "io.eventsourcingdb.test.foo"
      )

    second_event =
      create_test_eventcandidate("/test", %{"value" => 42},
        type: "io.eventsourcingdb.test.bar"
      )

    EventSourcingDB.write_events!(client, [first_event, second_event])

    events =
      EventSourcingDB.observe_events!(client, "/", %ObserveEventsOptions{
        recursive: true,
        from_latest_event: %FromLatestEventOptions{
          subject: "/test",
          type: "io.eventsourcingdb.test.bar",
          if_event_is_missing: :read_everything
        }
      })
      |> Enum.take(1)

    assert length(events) == 1
    assert Enum.at(events, 0).data["value"] == 42
  end
end
