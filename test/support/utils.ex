defmodule EventSourcingDBTest.Utils do
  @moduledoc false
  alias EventSourcingDB.Errors.DbApiError
  alias EventSourcingDB.Event
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.TestContainer
  import ExUnit.Assertions
  import ExUnit.Callbacks

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

  # Starts a test container, and stops it once the tests are done, for setup
  # and setup_all to hand it to the tests as esdb.
  @spec start_container(TestContainer.t()) :: %{esdb: Testcontainers.Container.t()}
  def start_container(config \\ test_container()) do
    {:ok, esdb} = TestContainer.start(config)
    on_exit(fn -> TestContainer.stop(esdb) end)

    %{esdb: esdb}
  end

  # The API that the server in the container offers, which the test finds out
  # without the client SDK, so that it can expect what that API answers.
  @spec server_api(Testcontainers.Container.t()) :: :v1 | :v2
  def server_api(container) do
    url = TestContainer.get_base_url(container) <> "api/v2/system/ping"

    case Req.get!(url, retry: false, decode_body: false) do
      %Req.Response{status: 200} -> :v2
      %Req.Response{status: 404} -> :v1
    end
  end

  # Returns what the test expects from the API that the server in the
  # container offers, given as v1: and v2:.
  @spec on_api(Testcontainers.Container.t(), keyword()) :: any()
  def on_api(container, expectations) do
    Keyword.fetch!(expectations, server_api(container))
  end

  # Asserts that the result is a DbApiError with the given status and code,
  # whose description the server gave, without depending on its wording,
  # which differs between the versions of EventSourcingDB: the description
  # starts with the given prefix and contains each of the given parts, and the
  # error names it in the SDK's own format.
  @spec assert_db_api_error(any(), pos_integer(), String.t() | nil, String.t(), [String.t()]) ::
          DbApiError.t()
  def assert_db_api_error(result, status, code, prefix \\ "", parts \\ []) do
    assert {:error, %DbApiError{description: description} = error} = result
    assert error.status == status
    assert error.code == code
    assert is_binary(description)

    assert String.starts_with?(description, prefix),
           "#{inspect(description)} does not start with #{inspect(prefix)}"

    for part <- parts do
      assert String.contains?(description, part),
             "#{inspect(description)} does not contain #{inspect(part)}"
    end

    assert Exception.message(error) =~ String.trim_trailing(description)

    error
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
