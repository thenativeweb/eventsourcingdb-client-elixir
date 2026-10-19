defmodule EventSourcingDBTest.RegisterEventSchema do
  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils
  setup do: start_container()

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

    assert_db_api_error(
      result,
      on_api(esdb, v1: 400, v2: 200),
      on_api(esdb, v1: nil, v2: ErrorCode.event_schema_not_object())
    )
  end

  test "fails to register a schema for an event type that has one already", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert {:ok, _event} =
             EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    result = EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    assert_db_api_error(
      result,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.event_schema_already_registered()
    )
  end

  test "fails to write an event that violates the schema of its type", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert {:ok, _event} =
             EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", @schema)

    result =
      EventSourcingDB.write_events(client, [
        create_test_eventcandidate("/test", %{"id" => 42, "name" => "Jane Doe"})
      ])

    assert_db_api_error(
      result,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.event_schema_violated()
    )
  end
end
