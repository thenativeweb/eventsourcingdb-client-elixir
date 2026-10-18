defmodule EventSourcingDBTest.RegisterEventSchema do
  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.Errors.DbApiError
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils
  import Testcontainers.ExUnit

  container(:esdb, test_container())

  @schema %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}, "name" => %{"type" => "string"}},
    "required" => ["id", "name"]
  }

  test "register event schema", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result =
      client
      |> EventSourcingDB.register_event_schema("io.eventsourcingdb.test", %{
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
      })

    assert {:ok, %EventSourcingDB.ManagementEvent{} = event} = result
    assert event.type == "io.eventsourcingdb.api.event-schema-registered"
    assert event.data["type"] == "io.eventsourcingdb.test"
    assert event.data["schema"]["required"] == ["id", "name"]
    refute Map.has_key?(event.data, "eventType")
  end

  test "register invalid schema", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result =
      client
      |> EventSourcingDB.register_event_schema("io.eventsourcingdb.test", %{"x" => "csie"})

    assert {:error, %DbApiError{status: 400}} = result
  end

  test "fails to register a schema for an event type that has one already", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert {:ok, _event} =
             EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    result = EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    assert_db_api_error(result, 409, ErrorCode.event_schema_already_registered())
  end

  test "fails to write an event that violates the schema of its type", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert {:ok, _event} =
             EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    result =
      EventSourcingDB.write_events(client, [
        create_test_eventcandidate("/test", %{"id" => 42, "name" => "Jane Doe"})
      ])

    assert_db_api_error(result, 409, ErrorCode.event_schema_violated())
  end
end
