defmodule EventSourcingDBTest.RunEventQLQuery do
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "reads no rows if the query does not return any rows", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    rows =
      EventSourcingDB.run_eventql_query!(
        client,
        "FROM e IN events ORDER BY e.time DESC TOP 100 PROJECT INTO e"
      )

    assert Enum.empty?(rows)
  end

  test "reads all rows the query returns", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 21}),
      create_test_eventcandidate("/test", %{"value" => 42})
    ]

    EventSourcingDB.write_events!(client, event_candidates)

    rows =
      EventSourcingDB.run_eventql_query!(
        client,
        "FROM e IN events PROJECT INTO e"
      )
      |> Enum.to_list()

    assert length(rows) == 2

    assert match?(%{"id" => "0", "data" => %{"value" => 21}}, Enum.at(rows, 0))
    assert match?(%{"id" => "1", "data" => %{"value" => 42}}, Enum.at(rows, 1))
  end

  test "reads rows with primitive number values", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 42})])

    rows =
      EventSourcingDB.run_eventql_query!(
        client,
        "FROM e IN events PROJECT INTO e.data.value"
      )
      |> Enum.to_list()

    assert length(rows) == 1
    assert Enum.at(rows, 0) == 42
  end

  test "reads rows with primitive boolean values", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 42})])

    rows =
      EventSourcingDB.run_eventql_query!(
        client,
        "FROM e IN events PROJECT INTO e.data.value > 0"
      )
      |> Enum.to_list()

    assert length(rows) == 1
    assert Enum.at(rows, 0) == true
  end

  test "reads rows with primitive string values", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    EventSourcingDB.write_events!(client, [
      create_test_eventcandidate("/test", %{"value" => "hello there!"})
    ])

    rows =
      EventSourcingDB.run_eventql_query!(
        client,
        "FROM e IN events PROJECT INTO e.data.value"
      )
      |> Enum.to_list()

    assert length(rows) == 1
    assert Enum.at(rows, 0) == "hello there!"
  end
end
