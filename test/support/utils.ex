defmodule EventsourcingdbTest.Utils do
  alias Eventsourcingdb.Events.Event
  alias Eventsourcingdb.Events.EventCandidate
  import ExUnit.Assertions

  def create_test_eventcandidate(subject, data) do
    %EventCandidate{
      type: "io.eventsourcingdb.test",
      subject: subject,
      source: "https://eventsourcingdb.io",
      data: data
    }
  end

  def create_numbered_eventcandidates(count) do
    1..count
    |> Enum.map(fn i -> create_test_eventcandidate("/test", %{"value" => i}) end)
  end

  @spec assert_event_match_eventcandidate(Event.t(), EventCandidate.t(), any(), any()) :: any()
  def assert_event_match_eventcandidate(
        event,
        candidate,
        _previous_event_hash,
        _expected_id
      ) do
    # check content
    assert event.data == candidate.data, "Data mismatch"
    assert event.source == candidate.source, "Source mismatch"
    assert event.subject == candidate.subject, "Subject mismatch"
    assert event.type == candidate.type, "Type mismatch"

    # check metadata
    assert event.datacontenttype == "application/json",
           "Data content type should be application/json"

    assert String.length(event.hash) == 64, "Hash should be present"
  end
end
