defmodule EventsourcingdbTest.WriteEvents do
  alias Eventsourcingdb.Errors.ApiError
  alias Eventsourcingdb.IsEventQLTrue
  alias Eventsourcingdb.IsSubjectOnEventId
  alias Eventsourcingdb.IsSubjectPopulated
  alias Eventsourcingdb.IsSubjectPristine
  alias Eventsourcingdb.TestContainer
  import EventsourcingdbTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new())

  test "write single event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write single event (map)", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = %{
      type: "io.eventsourcingdb.test",
      subject: "/test",
      source: "https://eventsourcingdb.io",
      data: %{"value" => 1}
    }

    written =
      Eventsourcingdb.write_events!(client, [event_candidate])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write multiple events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)
    written = Eventsourcingdb.write_events!(client, event_candidates)

    assert_event_match_eventcandidates(written, event_candidates)
  end

  test "write event with is subject pristine condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate], [
        %IsSubjectPristine{subject: event_candidate.subject}
      ])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write event with is subject pristine condition on non-empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    Eventsourcingdb.write_events!(client, [event_candidate])

    written =
      Eventsourcingdb.write_events(client, [event_candidate], [
        %IsSubjectPristine{subject: event_candidate.subject}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write event with is subject populated condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      Eventsourcingdb.write_events(client, [event_candidate], [
        %IsSubjectPopulated{subject: event_candidate.subject}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write event with is subject populated condition on non-empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    initial_event =
      Eventsourcingdb.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])
      |> Enum.at(0)

    expected_event_id = String.to_integer(initial_event.id) + 1
    event_candidate = create_test_eventcandidate("/test", %{"value" => 2})

    written =
      Eventsourcingdb.write_events!(client, [event_candidate], [
        %IsSubjectPopulated{subject: event_candidate.subject}
      ])

    assert_event_match_eventcandidate(
      Enum.at(written, 0),
      event_candidate,
      initial_event.hash,
      expected_event_id
    )
  end

  test "write multiple events with IsSubjectPristine condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 1})
    ]

    written =
      Eventsourcingdb.write_events!(client, event_candidates, [
        %IsSubjectPristine{subject: Enum.at(event_candidates, 0).subject}
      ])

    assert_event_match_eventcandidates(written, event_candidates)
  end

  test "write multiple events with IsSubjectPristine condition on non-empty subject", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    fill_event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    Eventsourcingdb.write_events!(client, [fill_event_candidate])

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      fill_event_candidate
    ]

    written =
      Eventsourcingdb.write_events(client, event_candidates, [
        %IsSubjectPristine{subject: fill_event_candidate.subject}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write event with IsSubjectOnEventId condition on non-empty subject with correct id", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    event = Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    written =
      Eventsourcingdb.write_events(client, [event_candidate], [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: event.id}
      ])

    assert match?({:ok, _}, written)
  end

  test "write event with IsSubjectOnEventId condition on non-empty subject with wrong id", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    written =
      Eventsourcingdb.write_events(client, [event_candidate], [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: "100"}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write multiple events with IsSubjectOnEventId condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 1})
    ]

    written =
      Eventsourcingdb.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: Enum.at(event_candidates, 0).subject, event_id: "100"}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write multiple events with IsSubjectOnEventId condition on non-empty subject with correct id",
       %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    event = Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    event_candidates = [
      create_test_eventcandidate("/test2", %{"value" => 1}),
      event_candidate
    ]

    written =
      Eventsourcingdb.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: event.id}
      ])

    assert match?({:ok, _}, written)
  end

  test "write multiple events with IsSubjectOnEventId condition on non-empty subject with wrong id",
       %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    event_candidates = [
      create_test_eventcandidate("/test2", %{"value" => 1}),
      event_candidate
    ]

    written =
      Eventsourcingdb.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: "100"}
      ])

    assert match?({:error, %ApiError{reason: "state conflict: precondition failed\n"}}, written)
  end

  test "write multiple events with IsEventQL condition", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 1})
    ]

    written =
      Eventsourcingdb.write_events(client, event_candidates, [
        %IsEventQLTrue{query: "FROM e IN events PROJECT INTO COUNT() == 0"}
      ])

    assert match?({:ok, _}, written)
  end

  test "write single event with traceparent", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate =
      create_test_eventcandidate("/test", %{"value" => 1},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00"
      )

    event = Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    assert_event_match_eventcandidate(event, event_candidate)
  end

  test "write single event with traceparent and state", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate =
      create_test_eventcandidate("/test", %{"value" => 1},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00",
        tracestate: "state=12345"
      )

    event = Eventsourcingdb.write_events!(client, [event_candidate]) |> Enum.at(0)

    assert_event_match_eventcandidate(event, event_candidate)
  end
end
