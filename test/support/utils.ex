defmodule EventsourcingdbTest.Utils do
  @moduledoc false
  alias Eventsourcingdb.Event
  alias Eventsourcingdb.EventCandidate
  import ExUnit.Assertions

  @spec create_test_eventcandidate(String.t(), map()) :: EventCandidate.t()
  def create_test_eventcandidate(subject, data) do
    %EventCandidate{
      type: "io.eventsourcingdb.test",
      subject: subject,
      source: "https://eventsourcingdb.io",
      data: data
    }
  end

  @spec create_test_eventcandidate(String.t(), map(), keyword()) :: EventCandidate.t()
  def create_test_eventcandidate(subject, data, additional) do
    config = create_test_eventcandidate(subject, data)
    struct(config, additional)
  end

  def create_numbered_eventcandidates(count) do
    1..count
    |> Enum.map(fn i -> create_test_eventcandidate("/test", %{"value" => i}) end)
  end

  @spec assert_event_match_eventcandidate(
          Event.t(),
          EventCandidate.t(),
          String.t(),
          non_neg_integer()
        ) :: any()
  def assert_event_match_eventcandidate(
        event,
        candidate,
        previous_event_hash,
        expected_id
      ) do
    assert_event_match_eventcandidate(event, candidate)

    assert event.id == Integer.to_string(expected_id), "ID should match"
    assert event.predecessorhash == previous_event_hash, "Previous hash should match"
  end

  @spec assert_event_match_eventcandidate(Event.t(), EventCandidate.t()) :: any()
  def assert_event_match_eventcandidate(event, candidate) do
    # check content
    assert event.data == candidate.data, "Data mismatch"
    assert event.source == candidate.source, "Source mismatch"
    assert event.subject == candidate.subject, "Subject mismatch"
    assert event.type == candidate.type, "Type mismatch"

    # check metadata
    assert event.datacontenttype == "application/json",
           "Data content type should be application/json"

    assert String.length(event.hash) == 64, "Hash should be present"
    assert not is_nil(event.id), "ID should be present"
    assert not is_nil(event.predecessorhash), "Previous hash should be present"
    assert event.specversion == "1.0", "Spec version should be 1.0"
  end

  @spec assert_event_match_eventcandidates([Event.t()], [EventCandidate.t()]) :: any()
  def assert_event_match_eventcandidates(events, candidates) do
    assert length(events) == length(candidates)

    Enum.zip(events, candidates)
    |> Enum.each(fn {event, candidate} ->
      assert_event_match_eventcandidate(event, candidate)
    end)
  end
end
