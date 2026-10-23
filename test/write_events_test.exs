defmodule EventSourcingDBTest.WriteEvents do
  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.Errors.IncompatibleServer
  alias EventSourcingDB.Event
  alias EventSourcingDB.IsEventQLQueryTrue
  alias EventSourcingDB.IsSubjectOnEventId
  alias EventSourcingDB.IsSubjectPopulated
  alias EventSourcingDB.IsSubjectPristine
  alias EventSourcingDB.PreconditionOptions
  alias EventSourcingDB.ReadEventsOptions
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  @moduletag timeout: container_test_timeout()

  setup do: start_container()

  test "write single event", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      EventSourcingDB.write_events!(client, [event_candidate])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write single event (map)", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = %{
      type: "io.eventsourcingdb.test",
      subject: "/test",
      source: "https://EventSourcingDB.io",
      data: %{"value" => 1}
    }

    written =
      EventSourcingDB.write_events!(client, [event_candidate])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write multiple events", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = create_numbered_eventcandidates(10)
    written = EventSourcingDB.write_events!(client, event_candidates)

    assert_event_match_eventcandidates(written, event_candidates)
  end

  test "write event with is subject pristine condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      EventSourcingDB.write_events!(client, [event_candidate], [
        %IsSubjectPristine{subject: event_candidate.subject}
      ])

    assert_event_match_eventcandidate(Enum.at(written, 0), event_candidate)
  end

  test "write event with is subject pristine condition on non-empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    EventSourcingDB.write_events!(client, [event_candidate])

    written =
      EventSourcingDB.write_events(client, [event_candidate], [
        %IsSubjectPristine{subject: event_candidate.subject}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write event with is subject populated condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})

    written =
      EventSourcingDB.write_events(client, [event_candidate], [
        %IsSubjectPopulated{subject: event_candidate.subject}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write event with is subject populated condition on non-empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    initial_event =
      EventSourcingDB.write_events!(client, [create_test_eventcandidate("/test", %{"value" => 1})])
      |> Enum.at(0)

    expected_event_id = String.to_integer(initial_event.id) + 1
    event_candidate = create_test_eventcandidate("/test", %{"value" => 2})

    written =
      EventSourcingDB.write_events!(client, [event_candidate], [
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
      EventSourcingDB.write_events!(client, event_candidates, [
        %IsSubjectPristine{subject: Enum.at(event_candidates, 0).subject}
      ])

    assert_event_match_eventcandidates(written, event_candidates)
  end

  test "write multiple events with IsSubjectPristine condition on non-empty subject", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    fill_event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    EventSourcingDB.write_events!(client, [fill_event_candidate])

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      fill_event_candidate
    ]

    written =
      EventSourcingDB.write_events(client, event_candidates, [
        %IsSubjectPristine{subject: fill_event_candidate.subject}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write event with IsSubjectOnEventId condition on non-empty subject with correct id", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    event = EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    written =
      EventSourcingDB.write_events(client, [event_candidate], [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: event.id}
      ])

    assert match?({:ok, _}, written)
  end

  test "write event with IsSubjectOnEventId condition on non-empty subject with wrong id", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    written =
      EventSourcingDB.write_events(client, [event_candidate], [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: "100"}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write multiple events with IsSubjectOnEventId condition on empty subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 1})
    ]

    written =
      EventSourcingDB.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: Enum.at(event_candidates, 0).subject, event_id: "100"}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write multiple events with IsSubjectOnEventId condition on non-empty subject with correct id",
       %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    event = EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    event_candidates = [
      create_test_eventcandidate("/test2", %{"value" => 1}),
      event_candidate
    ]

    written =
      EventSourcingDB.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: event.id}
      ])

    assert match?({:ok, _}, written)
  end

  test "write multiple events with IsSubjectOnEventId condition on non-empty subject with wrong id",
       %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate = create_test_eventcandidate("/test", %{"value" => 1})
    EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    event_candidates = [
      create_test_eventcandidate("/test2", %{"value" => 1}),
      event_candidate
    ]

    written =
      EventSourcingDB.write_events(client, event_candidates, [
        %IsSubjectOnEventId{subject: event_candidate.subject, event_id: "100"}
      ])

    assert_db_api_error(
      written,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  test "write multiple events with IsEventQL condition", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidates = [
      create_test_eventcandidate("/test", %{"value" => 1}),
      create_test_eventcandidate("/test", %{"value" => 1})
    ]

    written =
      EventSourcingDB.write_events(client, event_candidates, [
        %IsEventQLQueryTrue{query: "FROM e IN events PROJECT INTO COUNT() == 0"}
      ])

    assert match?({:ok, _}, written)
  end

  test "write single event with traceparent", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate =
      create_test_eventcandidate("/test", %{"value" => 1},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00"
      )

    event = EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    assert_event_match_eventcandidate(event, event_candidate)
  end

  test "write single event with traceparent and state", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    event_candidate =
      create_test_eventcandidate("/test", %{"value" => 1},
        traceparent: "00-01234567012345670123456701234567-0123456701234567-00",
        tracestate: "state=12345"
      )

    event = EventSourcingDB.write_events!(client, [event_candidate]) |> Enum.at(0)

    assert_event_match_eventcandidate(event, event_candidate)
  end

  describe "a precondition on a subject with recursive set to true" do
    # Each test writes the events of its setup, and then writes an event to
    # /books/42 with the precondition, which checks /books/42 together with
    # /books/42/pages below it, but not /books/43 next to it.

    test "IsSubjectPristine holds if neither the subject nor any subject below it has an event",
         %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      setup = write_setup!(client, ["/books/43"])

      result =
        write_with(client, %IsSubjectPristine{subject: "/books/42", options: recursive(true)})

      assert_recursive(esdb, client, result, setup, :holds)
    end

    test "IsSubjectPristine does not hold if a subject below it has an event", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      setup = write_setup!(client, ["/books/42/pages"])

      result =
        write_with(client, %IsSubjectPristine{subject: "/books/42", options: recursive(true)})

      assert_recursive(esdb, client, result, setup, :violated)
    end

    test "IsSubjectPopulated holds if a subject below it has an event", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      setup = write_setup!(client, ["/books/42/pages"])

      result =
        write_with(client, %IsSubjectPopulated{subject: "/books/42", options: recursive(true)})

      assert_recursive(esdb, client, result, setup, :holds)
    end

    test "IsSubjectPopulated does not hold if neither the subject nor any subject below it has an event",
         %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      setup = write_setup!(client, ["/books/43"])

      result =
        write_with(client, %IsSubjectPopulated{subject: "/books/42", options: recursive(true)})

      assert_recursive(esdb, client, result, setup, :violated)
    end

    test "IsSubjectOnEventId holds for the latest event among the subject and the subjects below it",
         %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      [_own, below] = setup = write_setup!(client, ["/books/42", "/books/42/pages"])

      result =
        write_with(client, %IsSubjectOnEventId{
          subject: "/books/42",
          event_id: below.id,
          options: recursive(true)
        })

      assert_recursive(esdb, client, result, setup, :holds)
    end

    test "IsSubjectOnEventId does not hold for the latest event of the subject alone if a subject below it has a later one",
         %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      [own, _below] = setup = write_setup!(client, ["/books/42", "/books/42/pages"])

      result =
        write_with(client, %IsSubjectOnEventId{
          subject: "/books/42",
          event_id: own.id,
          options: recursive(true)
        })

      assert_recursive(esdb, client, result, setup, :violated)
    end
  end

  describe "a precondition on a subject with recursive set to false" do
    # Each test writes the events of its setup, and then writes an event to
    # /books/42 with the precondition, which checks /books/42 alone, with and
    # without the v2 API.

    test "IsSubjectPristine holds if only a subject below it has an event", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      write_setup!(client, ["/books/42/pages"])

      result =
        write_with(client, %IsSubjectPristine{subject: "/books/42", options: recursive(false)})

      assert_holds(result)
    end

    test "IsSubjectPristine does not hold if the subject has an event", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      write_setup!(client, ["/books/42"])

      result =
        write_with(client, %IsSubjectPristine{subject: "/books/42", options: recursive(false)})

      assert_violated(esdb, result)
    end

    test "IsSubjectPopulated holds if the subject has an event", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      write_setup!(client, ["/books/42"])

      result =
        write_with(client, %IsSubjectPopulated{subject: "/books/42", options: recursive(false)})

      assert_holds(result)
    end

    test "IsSubjectPopulated does not hold if only a subject below it has an event", %{
      esdb: esdb
    } do
      client = TestContainer.get_client(esdb)
      write_setup!(client, ["/books/42/pages"])

      result =
        write_with(client, %IsSubjectPopulated{subject: "/books/42", options: recursive(false)})

      assert_violated(esdb, result)
    end

    test "IsSubjectOnEventId holds for the latest event of the subject alone", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)
      [own, _below] = write_setup!(client, ["/books/42", "/books/42/pages"])

      result =
        write_with(client, %IsSubjectOnEventId{
          subject: "/books/42",
          event_id: own.id,
          options: recursive(false)
        })

      assert_holds(result)
    end

    test "IsSubjectOnEventId does not hold for the latest event of a subject below it", %{
      esdb: esdb
    } do
      client = TestContainer.get_client(esdb)
      [_own, below] = write_setup!(client, ["/books/42", "/books/42/pages"])

      result =
        write_with(client, %IsSubjectOnEventId{
          subject: "/books/42",
          event_id: below.id,
          options: recursive(false)
        })

      assert_violated(esdb, result)
    end
  end

  defp recursive(recursive), do: PreconditionOptions.new(recursive: recursive)

  # Writes an event to each of the subjects in a single write, so that the
  # events follow the order of the subjects.
  defp write_setup!(client, subjects) do
    candidates = Enum.map(subjects, &create_test_eventcandidate(&1, %{"value" => 1}))
    EventSourcingDB.write_events!(client, candidates)
  end

  defp write_with(client, precondition) do
    candidate = create_test_eventcandidate("/books/42", %{"value" => 2})
    EventSourcingDB.write_events(client, [candidate], [precondition])
  end

  defp assert_holds(result) do
    assert {:ok, [%Event{subject: "/books/42"}]} = result
  end

  defp assert_violated(esdb, result) do
    assert_db_api_error(
      result,
      on_api(esdb, v1: 409, v2: 200),
      ErrorCode.precondition_violated(),
      "",
      ["precondition"]
    )
  end

  # Checking a precondition recursively needs the v2 API, so against a server
  # without it, the write fails before it is sent, and the events of the setup
  # remain the only ones.
  defp assert_recursive(esdb, client, result, setup, outcome) do
    case {server_api(esdb), outcome} do
      {:v2, :holds} ->
        assert_holds(result)

      {:v2, :violated} ->
        assert_violated(esdb, result)

      {:v1, _outcome} ->
        assert {:error, %IncompatibleServer{}} = result

        stored =
          EventSourcingDB.read_events!(client, "/", %ReadEventsOptions{recursive: true})
          |> Enum.map(& &1.id)

        assert stored == Enum.map(setup, & &1.id)
    end
  end
end
