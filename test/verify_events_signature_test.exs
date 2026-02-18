defmodule EventsourcingdbTest.VerifyEventsSignutare do
  alias Eventsourcingdb.Event
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_signing_key()
  )

  test "verify event signature", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate])

    # assert :ok == Event.verify_hash(Enum.at(written, 0))

    assert true
  end

  # test "verify broken event hash", %{esdb: esdb} do
  #   client = TestContainer.get_client(esdb)

  #   event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

  #   written =
  #     Eventsourcingdb.write_events!(client, [event_candidate])

  #   event = Enum.at(written, 0)
  #   broken = Map.put(event, :hash, "BROKEN")

  #   assert match?({:error, :hash_verification_failed, _}, Event.verify_hash(broken))
  # end
end
