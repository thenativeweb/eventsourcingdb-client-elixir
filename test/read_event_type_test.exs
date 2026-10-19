defmodule EventSourcingDBTest.ReadEventType do
  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.EventType
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  @moduletag timeout: container_test_timeout()

  setup do: start_container()

  test "fails if the event type does not exist", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = EventSourcingDB.read_event_type(client, "non.existent.eventType")

    assert_db_api_error(
      result,
      on_api(esdb, v1: 404, v2: 200),
      ErrorCode.event_type_unknown(),
      "event type "
    )
  end

  test "fails if the event type is malformed", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = EventSourcingDB.read_event_type(client, "malformed.eventType.")

    assert_db_api_error(
      result,
      on_api(esdb, v1: 400, v2: 200),
      on_api(esdb, v1: nil, v2: ErrorCode.event_type_malformed()),
      "",
      ["event type"]
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
             %EventType{type: "io.eventsourcingdb.test.foo", has_events: true},
             result
           )
  end
end
