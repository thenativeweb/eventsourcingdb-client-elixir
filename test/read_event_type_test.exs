defmodule EventSourcingDBTest.ReadEventType do
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.EventType
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, test_container())

  test "fails if the event type does not exist", %{esdb: esdb} do
    client = client_reporting_status(esdb)

    result = EventSourcingDB.read_event_type(client, "non.existent.eventType")

    assert_api_error(result, "event type ")
    assert_received {:status, 404}
  end

  test "fails if the event type is malformed", %{esdb: esdb} do
    client = client_reporting_status(esdb)

    result = EventSourcingDB.read_event_type(client, "malformed.eventType.")

    assert_api_error(result, "", ["event type"])
    assert_received {:status, 400}
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
             %EventType{type: "io.eventsourcingdb.test.foo", has_events: true},
             result
           )
  end
end
