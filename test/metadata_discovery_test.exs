defmodule EventsourcingdbTest.MetadataDiscoveryTests do
  alias Eventsourcingdb.TestContainer
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "register event schema", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result =
      client
      |> Eventsourcingdb.register_event_schema("io.eventsourcingdb.test", %{
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

    assert match?({:ok, _}, result)
  end

  test "register invalid schema", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    result =
      client
      |> Eventsourcingdb.register_event_schema("io.eventsourcingdb.test", %{"x" => "csie"})

    assert match?({:error, :api_error, _}, result)
  end
end
