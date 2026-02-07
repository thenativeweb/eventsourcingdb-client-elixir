defmodule EventsourcingdbTest.ReadSubjectsTests do
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "read no subjects when database is empty", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    result = Eventsourcingdb.read_subjects(client, "/")

    assert Enum.empty?(result)
  end

  test "reads all subjects", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test/1", %{"value" => 21}),
      create_test_eventcandidate("/test/2", %{"value" => 42})
    ]

    Eventsourcingdb.write_events!(client, event_candidates)

    result = Eventsourcingdb.read_subjects(client, "/")

    assert ["/", "/test", "/test/1", "/test/2"] == Enum.to_list(result)
  end

  test "reads all subjects from the base subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test/1", %{"value" => 21}),
      create_test_eventcandidate("/test/2", %{"value" => 42})
    ]

    Eventsourcingdb.write_events!(client, event_candidates)

    result = Eventsourcingdb.read_subjects(client, "/test")

    assert ["/test", "/test/1", "/test/2"] == Enum.to_list(result)
  end
end
