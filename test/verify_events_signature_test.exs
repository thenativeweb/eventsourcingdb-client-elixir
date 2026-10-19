defmodule EventSourcingDBTest.VerifyEventsSignature do
  alias EventSourcingDB.Event
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.Errors.SignatureMissing
  alias EventSourcingDB.Errors.SignatureVerificationFailed
  alias EventSourcingDB.Errors.HashVerificationFailed
  import EventSourcingDBTest.Utils
  use ExUnit.Case

  @moduletag timeout: container_test_timeout()

  setup do: start_container(TestContainer.with_signing_key(test_container()))

  test "verify signature with missing signature" do
    assert {:ok, esdb} = TestContainer.start(test_container())
    client = TestContainer.get_client(esdb)

    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)

    assert match?({:error, %SignatureMissing{}}, Event.verify_signature(event, public_key))

    assert :ok = TestContainer.stop(esdb)
  end

  test "get signing key returns the key the verification key belongs to", %{esdb: esdb} do
    signing_key = TestContainer.get_signing_key(esdb)

    assert {public_key, ^signing_key} = :crypto.generate_key(:eddsa, :ed25519, signing_key)
    assert public_key == TestContainer.get_verification_key(esdb)
  end

  test "get signing key raises without a signing key" do
    assert {:ok, esdb} = TestContainer.start(test_container())

    assert_raise ArgumentError, "the container was started without a signing key", fn ->
      TestContainer.get_signing_key(esdb)
    end

    assert :ok = TestContainer.stop(esdb)
  end

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

  test "verify signature with tampered signature", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)
    tampered = Map.put(event, :signature, event.signature <> "0123456789abcdef")

    assert match?(
             {:error, %SignatureVerificationFailed{}},
             Event.verify_signature(tampered, verification_key)
           )
  end

  test "verify event signature", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    event = Enum.at(written, 0)

    assert :ok == Event.verify_signature(event, verification_key)
  end

  test "verify event signatures of read events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    EventSourcingDB.write_events!(client, [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 2},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00",
        tracestate: "state=12345"
      )
    ])

    events = EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()

    assert length(events) == 2

    for event <- events do
      assert :ok == Event.verify_signature(event, verification_key)
    end
  end

  test "verify event signatures of data that Jason encodes differently", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    verification_key = TestContainer.get_verification_key(esdb)

    written =
      EventSourcingDB.write_events!(client, [
        create_test_eventcandidate("/test", %{"title" => "Tom & Jerry <b>", "pages" => 1.0e21})
      ])

    read = EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()

    for event <- written ++ read do
      assert :ok == Event.verify_signature(event, verification_key)
    end
  end
end
