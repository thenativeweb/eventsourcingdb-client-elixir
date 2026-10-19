defmodule EventSourcingDBTest.ReadEventTypes do
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.EventType
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  @moduletag timeout: container_test_timeout()

  setup do: start_container()

  test "reads no event types if the database is empty", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = EventSourcingDB.read_event_types!(client)

    assert Enum.empty?(result)
  end

  test "reads all event types", %{esdb: esdb} do
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

    result = EventSourcingDB.read_event_types!(client) |> Enum.to_list()

    assert result ==
             [
               %EventType{
                 type: "io.eventsourcingdb.test.bar",
                 has_events: true,
                 schema: nil
               },
               %EventType{
                 type: "io.eventsourcingdb.test.foo",
                 has_events: true,
                 schema: nil
               }
             ]
  end

  test "supports reading event schemas", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{
          "type" => "string"
        },
        "name" => %{
          "type" => "string"
        }
      },
      "required" => ["id", "name"]
    }

    EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", schema)

    result = EventSourcingDB.read_event_types!(client) |> Enum.to_list()

    assert result ==
             [
               %EventType{
                 type: "io.eventsourcingdb.test",
                 has_events: false,
                 schema: schema
               }
             ]
  end
end
