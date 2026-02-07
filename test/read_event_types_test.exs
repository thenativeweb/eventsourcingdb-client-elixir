defmodule EventsourcingdbTest.ReadEventTypes do
  alias Eventsourcingdb.Events.EventCandidate
  alias Eventsourcingdb.Events.EventType
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "reads no event types if the database is empty", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result = Eventsourcingdb.read_event_types(client)

    assert Enum.empty?(result)
  end

  test "reads all event types", %{esdb: esdb} do
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

    result = Eventsourcingdb.read_event_types(client) |> Enum.to_list()

    assert result ==
             [
               %EventType{
                 event_type: "io.eventsourcingdb.test.bar",
                 is_phantom: false,
                 schema: nil
               },
               %EventType{
                 event_type: "io.eventsourcingdb.test.foo",
                 is_phantom: false,
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

    Eventsourcingdb.register_event_schema(client, "io.eventsourcingdb.test", schema)

    result = Eventsourcingdb.read_event_types(client) |> Enum.to_list()

    assert result ==
             [
               %EventType{
                 event_type: "io.eventsourcingdb.test",
                 is_phantom: true,
                 schema: schema
               }
             ]
  end
end
