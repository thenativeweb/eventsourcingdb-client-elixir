defmodule EventsourcingdbTest.RunEventQLQuery do
  alias Eventsourcingdb.TestContainer
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "run empty query", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    rows =
      Eventsourcingdb.run_eventql_query(
        client,
        "FROM e IN events ORDER BY e.time DESC TOP 100 PROJECT INTO e"
      )

    assert Enum.empty?(rows)
  end
end
