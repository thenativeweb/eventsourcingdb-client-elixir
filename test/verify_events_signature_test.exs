defmodule EventSourcingDBTest.VerifyEventsSignutare do
  alias EventSourcingDB.Event
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.Errors.SignatureMissing
  alias EventSourcingDB.Errors.HashVerificationFailed
  import EventSourcingDBTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_signing_key()
  )

  test "verify signature with missing signature" do
    assert {:ok, esdb} = Testcontainers.start_container(TestContainer.new())
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)

    assert match?({:error, %SignatureMissing{}}, Event.verify_signature(event, verification_key))

    assert :ok = Testcontainers.stop_container(esdb.container_id)
  end

  # @TODO fix this test
  test "verify signature with broken event hash", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)
    broken = Map.put(event, :hash, "BROKEN")

    assert match?(
             {:error, %HashVerificationFailed{}},
             Event.verify_signature(broken, verification_key)
           )
  end

  # @TODO fix this test
  test "verify event signature", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)

    assert :ok == Event.verify_signature(event, verification_key)
  end
end
