defmodule EventsourcingdbTest.VerifyEvents do
  alias Eventsourcingdb.Events.Event
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "verify event hash", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate])

    assert :ok == Event.verify_hash(Enum.at(written, 0))
  end
end
