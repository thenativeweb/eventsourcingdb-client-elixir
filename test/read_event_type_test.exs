defmodule EventsourcingdbTest.ReadEventType do
  alias Eventsourcingdb.EventCandidate
  alias Eventsourcingdb.EventType
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "fails if the event type does not exist", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = Eventsourcingdb.read_event_type(client, "non.existent.eventType")

    assert match?({:error, :api_error, "event type 'non.existent.eventType' not found\n"}, result)
  end

  test "fails if the event type is malformed", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = Eventsourcingdb.read_event_type(client, "malformed.eventType.")

    assert match?({:error, :api_error, "invalid event type: 'malformed.eventType.'\n"}, result)
  end

  test "read an existing event type", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    Eventsourcingdb.write_events!(client, [
      %EventCandidate{
        create_test_eventcandidate("/test/1", %{"value" => 21})
        | type: "io.eventsourcingdb.test.foo"
      },
      %EventCandidate{
        create_test_eventcandidate("/test/2", %{"value" => 42})
        | type: "io.eventsourcingdb.test.bar"
      }
    ])

    result = Eventsourcingdb.read_event_type!(client, "io.eventsourcingdb.test.foo")

    assert match?(
             %EventType{event_type: "io.eventsourcingdb.test.foo", is_phantom: false},
             result
           )
  end
end
