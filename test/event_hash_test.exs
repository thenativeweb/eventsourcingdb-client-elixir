defmodule EventSourcingDBTest.EventHash do
  alias EventSourcingDB.Errors.HashVerificationFailed
  alias EventSourcingDB.Errors.UnsupportedHashVersion
  alias EventSourcingDB.Event
  use ExUnit.Case, async: true

  # Events as EventSourcingDB returned them: of version 1 from EventSourcingDB
  # 1.2, and of version 2 from a release that writes hashes of version 2. Each
  # time, the first event has no trace context, and the second one has.
  @events_v1 """
  [{"source":"https://library.eventsourcingdb.io","subject":"/books/42","type":"io.eventsourcingdb.library.book-acquired","specversion":"1.0","id":"0","time":"2026-10-18T13:58:57.136925959Z","datacontenttype":"application/json","predecessorhash":"0000000000000000000000000000000000000000000000000000000000000000","data":{"author":"Arthur C. Clarke","isbn":"978-0756906788","title":"2001 – A Space Odyssey"},"hash":"61827e6ae4931aa39ee0a31f9e131bcbb2a05dab99266b10ecccd056be3078e0","signature":null},{"source":"https://library.eventsourcingdb.io","subject":"/books/42","type":"io.eventsourcingdb.library.book-borrowed","traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01","tracestate":"vendor=value","specversion":"1.0","id":"1","time":"2026-10-18T13:58:57.136925959Z","datacontenttype":"application/json","predecessorhash":"61827e6ae4931aa39ee0a31f9e131bcbb2a05dab99266b10ecccd056be3078e0","data":{"borrower":"Dave","days":14},"hash":"b50556373b62340b1f27ea82d732e54cec9bbef03ddf2f400b4aae336ff1eedc","signature":null}]
  """

  @events_v2 """
  [{"source":"https://library.eventsourcingdb.io","subject":"/books/42","type":"io.eventsourcingdb.library.book-acquired","specversion":"1.0","id":"0","time":"2026-10-18T13:59:01.161867461Z","datacontenttype":"application/json","predecessorhash":"0000000000000000000000000000000000000000000000000000000000000000","data":{"author":"Arthur C. Clarke","isbn":"978-0756906788","title":"2001 – A Space Odyssey"},"hash":"esdb:hash:v2:73279a1cc97024554e50b27cf871610509dafb88170c24291c3dc61b881cedb8","signature":null},{"source":"https://library.eventsourcingdb.io","subject":"/books/42","type":"io.eventsourcingdb.library.book-borrowed","traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01","tracestate":"vendor=value","specversion":"1.0","id":"1","time":"2026-10-18T13:59:01.161867461Z","datacontenttype":"application/json","predecessorhash":"esdb:hash:v2:73279a1cc97024554e50b27cf871610509dafb88170c24291c3dc61b881cedb8","data":{"borrower":"Dave","days":14},"hash":"esdb:hash:v2:f4983bee4d06850379d296eeb5a18c8102b2eed5948fb058ea15b6c8269bdb2e","signature":null}]
  """

  describe "a hash of version 1" do
    test "verifies" do
      for event <- events(@events_v1) do
        assert Event.verify_hash(event) == :ok
      end
    end

    test "does not cover traceparent and tracestate" do
      [_event, traced] = events(@events_v1)

      assert Event.verify_hash(%{traced | tracestate: "vendor=other"}) == :ok
    end

    test "fails to verify if the data was changed" do
      [event, _traced] = events(@events_v1)
      tampered = %{event | data: Map.put(event.data, "title", "2010 – Odyssey Two")}

      assert {:error, %HashVerificationFailed{expected: expected, actual: actual}} =
               Event.verify_hash(tampered)

      assert expected == event.hash
      assert actual =~ ~r/^[a-f0-9]{64}$/
      assert actual != expected
    end
  end

  describe "a hash of version 2" do
    test "verifies with a missing traceparent and tracestate" do
      [event, _traced] = events(@events_v2)

      assert event.traceparent == nil
      assert event.tracestate == nil
      assert Event.verify_hash(event) == :ok
    end

    test "verifies with a traceparent and a tracestate" do
      [_event, traced] = events(@events_v2)

      assert Event.verify_hash(traced) == :ok
    end

    test "fails to verify if the data was changed" do
      [event, _traced] = events(@events_v2)
      tampered = %{event | data: Map.put(event.data, "title", "2010 – Odyssey Two")}

      assert {:error, %HashVerificationFailed{expected: expected, actual: actual}} =
               Event.verify_hash(tampered)

      assert expected == event.hash
      assert actual =~ ~r/^esdb:hash:v2:[a-f0-9]{64}$/
      assert actual != expected
    end

    test "fails to verify if the tracestate was changed" do
      [_event, traced] = events(@events_v2)

      assert {:error, %HashVerificationFailed{}} =
               Event.verify_hash(%{traced | tracestate: "vendor=other"})
    end

    test "fails to verify if the traceparent was removed" do
      [_event, traced] = events(@events_v2)

      assert {:error, %HashVerificationFailed{}} =
               Event.verify_hash(%{traced | traceparent: nil})
    end
  end

  describe "a hash of an unknown version" do
    test "fails to verify with an error that names the version" do
      [event, _traced] = events(@events_v2)
      unknown = %{event | hash: "esdb:hash:v3:" <> String.duplicate("a", 64)}

      assert {:error, %UnsupportedHashVersion{version: "v3"} = error} =
               Event.verify_hash(unknown)

      assert Exception.message(error) =~ "v3"
    end

    test "fails to verify the signature with the same error" do
      [event, _traced] = events(@events_v2)

      unknown = %{
        event
        | hash: "esdb:hash:v3:" <> String.duplicate("a", 64),
          signature: "esdb:signature:v1:" <> String.duplicate("b", 128)
      }

      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, %UnsupportedHashVersion{version: "v3"}} =
               Event.verify_signature(unknown, public_key)
    end
  end

  defp events(json) do
    json
    |> Jason.decode!()
    |> Enum.map(&Event.new/1)
  end
end
