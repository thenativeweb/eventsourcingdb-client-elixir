defmodule EventSourcingDBTest.ReadEventType do
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.EventType
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "fails if the event type does not exist", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = EventSourcingDB.read_event_type(client, "non.existent.eventType")

    assert match?(
             {:error, %ApiError{reason: "event type 'non.existent.eventType' not found\n"}},
             result
           )
  end

  test "fails if the event type is malformed", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = EventSourcingDB.read_event_type(client, "malformed.eventType.")

    assert match?(
             {:error, %ApiError{reason: "invalid event type: 'malformed.eventType.'\n"}},
             result
           )
  end

  test "read an existing event type", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    EventSourcingDB.write_events!(client, [
      %EventCandidate{
        create_test_eventcandidate("/test/1", %{"value" => 21})
        | type: "io.eventsourcingdb.test.foo"
      },
      %EventCandidate{
        create_test_eventcandidate("/test/2", %{"value" => 42})
        | type: "io.eventsourcingdb.test.bar"
      }
    ])

    result = EventSourcingDB.read_event_type!(client, "io.eventsourcingdb.test.foo")

    assert match?(
             %EventType{event_type: "io.eventsourcingdb.test.foo", is_phantom: false},
             result
           )
  end
end
