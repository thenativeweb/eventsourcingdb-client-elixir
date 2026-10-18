defmodule EventSourcingDBTest.Utils do
  @moduledoc false
  alias EventSourcingDB.Errors.ApiError
  alias EventSourcingDB.Event
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.TestContainer
  import ExUnit.Assertions

  # The tests run against the image tag that EVENTSOURCINGDB_IMAGE_TAG names,
  # such as latest or preview, and against the default tag of the test
  # container if it is not set.
  @spec test_container() :: struct()
  def test_container() do
    case System.get_env("EVENTSOURCINGDB_IMAGE_TAG", "") do
      "" -> TestContainer.new()
      image_tag -> TestContainer.with_image_tag(TestContainer.new(), image_tag)
    end
  end

  # Returns the client of the container, which sends the status code of every
  # response to the calling process as {:status, status}, so that a test can
  # check it, too.
  @spec client_reporting_status(struct()) :: EventSourcingDB.Client.t()
  def client_reporting_status(container) do
    test_process = self()

    report_status = fn req ->
      Req.Request.append_response_steps(req,
        report_status: fn {request, response} ->
          send(test_process, {:status, response.status})
          {request, response}
        end
      )
    end

    client = TestContainer.get_client(container)
    %{client | req_options: client.req_options ++ [plugins: [report_status]]}
  end

  # Asserts that the result is an ApiError whose reason the server gave, without
  # depending on its wording, which EventSourcingDB 1.3 changes: the reason
  # starts with the given prefix, contains each of the given parts, and ends
  # with a newline, and the error names it in the SDK's own format.
  @spec assert_api_error(any(), String.t(), [String.t()]) :: any()
  def assert_api_error(result, prefix, parts \\ []) do
    assert {:error, %ApiError{reason: reason} = error} = result
    assert is_binary(reason)

    assert String.starts_with?(reason, prefix),
           "#{inspect(reason)} does not start with #{inspect(prefix)}"

    assert String.ends_with?(reason, "\n")

    for part <- parts do
      assert String.contains?(reason, part),
             "#{inspect(reason)} does not contain #{inspect(part)}"
    end

    assert Exception.message(error) == "API Error: #{reason}"
  end

  @spec create_test_eventcandidate(String.t(), map()) :: EventCandidate.t()
  def create_test_eventcandidate(subject, data) do
    %EventCandidate{
      type: "io.eventsourcingdb.test",
      subject: subject,
      source: "https://EventSourcingDB.io",
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

    assert event.hash =~ ~r/^(esdb:hash:v2:)?[a-f0-9]{64}$/, "Hash should be present"
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
