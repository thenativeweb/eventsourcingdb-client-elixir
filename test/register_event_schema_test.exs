defmodule EventSourcingDBTest.RegisterEventSchema do
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils
  import Testcontainers.ExUnit

  container(:esdb, test_container())

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

    assert match?({:error, %ApiError{}}, result)
  end
end
