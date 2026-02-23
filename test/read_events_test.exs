defmodule EventsourcingdbTest.ReadEvents do
  alias Eventsourcingdb.Client
  alias Eventsourcingdb.FromLatestEventOptions
  alias Eventsourcingdb.BoundOptions
  alias Eventsourcingdb.ReadEventsOptions
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "make read call", %{esdb: esdb} do
    result = TestContainer.get_client(esdb) |> Eventsourcingdb.read_events("/")
    {:ok, events} = result

    assert match?({:ok, _}, result)
    assert Enum.empty?(events)
  end

  test "read from unavailable server" do
    client =
      Client.new(
        base_url: "http://localhost:12345",
        api_token: "secrettoken",
        req_options: [retry: false]
      )

    stream = Eventsourcingdb.read_events(client, "/")

    assert match?({:error, :transmission_error, _}, stream)
  end

  test "make read call with event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    written =
      Eventsourcingdb.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])

    events = Eventsourcingdb.read_events!(client, "/test") |> Enum.to_list()

    assert events == written
  end

  test "make read call with multiple events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)

    written =
      Eventsourcingdb.write_events!(client, event_candidates)

    events = Eventsourcingdb.read_events!(client, "/test") |> Enum.to_list()

    assert events == written
  end

  test "read from exact topic", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    Eventsourcingdb.write_events!(client, [event_candidate])
    Eventsourcingdb.write_events!(client, [create_test_eventcandidate("/wrong", %{"value" => 1})])

    events = Eventsourcingdb.read_events!(client, "/test") |> Enum.to_list()

    assert length(events) == 1
    assert_event_match_eventcandidate(Enum.at(events, 0), event_candidate)
  end

  test "read recursive", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate_parent = create_test_eventcandidate("/test", %{"value" => 1})
    event_candidate_child = create_test_eventcandidate("/test/sub", %{"value" => 2})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate_parent, event_candidate_child])

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{recursive: true})
      |> Enum.to_list()

    assert events == written
  end

  test "read not recursive", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate_parent = create_test_eventcandidate("/test", %{"value" => 1})
    event_candidate_child = create_test_eventcandidate("/test/sub", %{"value" => 2})

    Eventsourcingdb.write_events!(client, [event_candidate_parent, event_candidate_child])

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{recursive: false})
      |> Enum.to_list()

    assert Enum.count(events) == 1
    assert_event_match_eventcandidate(Enum.at(events, 0), event_candidate_parent)
  end

  test "read chronological", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)

    written =
      Eventsourcingdb.write_events!(client, event_candidates)

    events = Eventsourcingdb.read_events!(client, "/test") |> Enum.to_list()

    assert events == written
  end

  test "read anti-chronological", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)

    written =
      Eventsourcingdb.write_events!(client, event_candidates)

    events = Eventsourcingdb.read_events!(client, "/test") |> Enum.to_list() |> Enum.reverse()

    assert events != written
  end

  test "reads with lower bound", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    first_event = create_test_eventcandidate("/test", %{"value" => 23})
    second_event = create_test_eventcandidate("/test", %{"value" => 42})

    Eventsourcingdb.write_events!(client, [first_event, second_event])

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{
        lower_bound: %BoundOptions{
          id: "1",
          type: :inclusive
        },
        recursive: false
      })
      |> Enum.to_list()

    assert Enum.count(events) == 1
    assert Enum.at(events, 0).data["value"] == 42
  end

  test "reads with upper bound", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    first_event = create_test_eventcandidate("/test", %{"value" => 23})
    second_event = create_test_eventcandidate("/test", %{"value" => 42})

    Eventsourcingdb.write_events!(client, [first_event, second_event])

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{
        upper_bound: %BoundOptions{
          id: "0",
          type: :inclusive
        },
        recursive: false
      })
      |> Enum.to_list()

    assert Enum.count(events) == 1
    assert Enum.at(events, 0).data["value"] == 23
  end

  test "read everything from missing latest event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)
    Eventsourcingdb.write_events!(client, event_candidates)

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{
        from_latest_event: %FromLatestEventOptions{
          subject: "/",
          type: "io.eventsourcingdb.test.does-not-exist",
          if_event_is_missing: :read_nothing
        },
        recursive: false
      })

    assert Enum.empty?(events)
  end

  test "read from last event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)
    Eventsourcingdb.write_events!(client, event_candidates)

    Eventsourcingdb.write_events!(client, [create_test_eventcandidate("/marker", %{"value" => 1})])

    written = Eventsourcingdb.write_events!(client, event_candidates)

    events =
      Eventsourcingdb.read_events!(client, "/test", %ReadEventsOptions{
        from_latest_event: %FromLatestEventOptions{
          subject: "/marker",
          type: "io.eventsourcingdb.test",
          if_event_is_missing: :read_nothing
        },
        recursive: false
      })
      |> Enum.to_list()

    assert events == written
  end
end
