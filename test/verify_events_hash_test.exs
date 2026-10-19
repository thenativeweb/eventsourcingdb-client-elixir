defmodule EventSourcingDBTest.VerifyEvents do
  alias EventSourcingDB.Errors.HashVerificationFailed
  alias EventSourcingDB.Event
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  setup do: start_container()

  test "verify event hash", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      EventSourcingDB.write_events!(client, [event_candidate])

    assert :ok == Event.verify_hash(Enum.at(written, 0))
  end

  test "verify event hash with traceparent and tracestate", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate =
      create_test_eventcandidate("/test", %{"value" => 1},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00",
        tracestate: "state=12345"
      )

    written =
      EventSourcingDB.write_events!(client, [event_candidate])

    assert :ok == Event.verify_hash(Enum.at(written, 0))
  end

  test "verify event hashes of read events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    EventSourcingDB.write_events!(client, [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 2},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00"
      )
    ])

    events = EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()

    assert length(events) == 2

    for event <- events do
      assert :ok == Event.verify_hash(event)
    end
  end

  # Data that Jason encodes differently than EventSourcingDB sends it, which
  # escapes &, <, and >, writes 1e+21 rather than 1.0e21, and orders the keys
  # of every object, while Jason keeps the order of a map with more than 32
  # keys as it happens to be.
  @data_encoded_differently [
    %{"title" => "Tom & Jerry"},
    %{"html" => "<b>"},
    %{"pages" => 1.0e21},
    Map.new(1..40, &{"key#{String.pad_leading(Integer.to_string(&1), 2, "0")}", &1})
  ]

  test "verify event hashes of data that Jason encodes differently", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    candidates = Enum.map(@data_encoded_differently, &create_test_eventcandidate("/test", &1))
    written = EventSourcingDB.write_events!(client, candidates)
    read = EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()

    assert length(written) == 4
    assert length(read) == 4

    for event <- written ++ read do
      assert :ok == Event.verify_hash(event)
    end
  end

  test "verify broken event hash", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      EventSourcingDB.write_events!(client, [event_candidate])

    event = Enum.at(written, 0)
    broken = Map.put(event, :hash, "BROKEN")

    assert match?({:error, %HashVerificationFailed{}}, Event.verify_hash(broken))
  end
end
