defmodule EventSourcingDBTest.ApiV1 do
  alias EventSourcingDB.Client
  alias EventSourcingDB.ErrorCode

  alias EventSourcingDB.Errors.{
    ConnectionStalled,
    DbApiError,
    InvalidServerHeader,
    OutcomeUnknown,
    TransmissionError
  }

  alias EventSourcingDB.ReadSubjectsOptions
  alias EventSourcingDBTest.{FakeServer, StreamServer}
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  # The behavior of the client SDK that only servers without the v2 API show.

  # The texts of the errors as EventSourcingDB 1.2 sends them.
  @precondition_failed "state conflict: precondition failed\n"
  @capacity_exceeded "state conflict: exceeded max store capacity\n"
  @range_unsatisfiable "state conflict: fromLatestEvent results in an event ID greater than upperBound ID\n"
  @candidate_violates_schema "schema conflict: event candidate does not match schema: expected string, but got number\n"
  @schema_already_exists "schema conflict: schema already exists\n"
  @events_violate_schema "schema conflict: event with ID 0: missing properties: 'b'\n"
  @event_type_not_found "event type 'io.eventsourcingdb.test' not found\n"
  @read_only "the current operation mode conflicts with the given request: writing is not permitted\n"
  @license_expired "insufficient storage\n"

  describe "the code of an error" do
    for {call, status, text, code} <- [
          {:write_events, 409, @precondition_failed, :precondition_violated},
          {:write_events, 409, @capacity_exceeded, :capacity_exceeded},
          {:write_events, 409, @candidate_violates_schema, :event_schema_violated},
          {:register_event_schema, 409, @schema_already_exists, :event_schema_already_registered},
          {:register_event_schema, 409, @events_violate_schema, :event_schema_violated},
          {:read_events, 409, @range_unsatisfiable, :range_unsatisfiable},
          {:read_event_type, 404, @event_type_not_found, :event_type_unknown},
          {:write_events, 503, @read_only, :store_read_only},
          {:register_event_schema, 503, @read_only, :store_read_only},
          {:read_events, 503, @read_only, :store_read_only},
          {:read_event_type, 503, @read_only, :store_read_only},
          {:write_events, 507, @license_expired, :license_invalid}
        ] do
      @call call
      @status status
      @text text
      @code code

      test "is #{code} for #{call} with status #{status} and the text #{inspect(text)}" do
        url = start_v1(fn _request -> {@status, @text} end)

        assert {:error, %DbApiError{} = error} = run(@call, client(url))
        assert error.code == apply(ErrorCode, @code, [])
        assert error.status == @status
        assert error.description == @text
        assert error.details == nil
      end
    end

    for {call, status, text} <- [
          {:write_events, 409, "state conflict: something else\n"},
          {:write_events, 409, "schema conflict: something else\n"},
          {:write_events, 409, @schema_already_exists},
          {:register_event_schema, 409, @candidate_violates_schema},
          {:read_events, 409, @precondition_failed},
          {:read_event_type, 409, @precondition_failed},
          {:write_events, 404, "404 page not found\n"},
          {:read_events, 404, "404 page not found\n"},
          {:register_event_schema, 507, @license_expired},
          {:write_events, 400, "bad request\n"},
          {:write_events, 503, "server is shutting down\n"}
        ] do
      @call call
      @status status
      @text text

      test "is missing for #{call} with status #{status} and the text #{inspect(text)}" do
        url = start_v1(fn _request -> {@status, @text} end)

        assert {:error, %DbApiError{code: nil, status: @status, description: @text}} =
                 run(@call, client(url))
      end
    end

    test "is missing for an error that arrives within a stream" do
      url =
        start_v1(fn _request ->
          {:lines, [%{"type" => "error", "payload" => %{"error" => "something went wrong"}}]}
        end)

      {:ok, events} = EventSourcingDB.read_events(client(url), "/test")
      error = assert_raise DbApiError, fn -> Enum.to_list(events) end

      assert error == %DbApiError{description: "something went wrong", status: 200}
    end
  end

  describe "the outcome of a write" do
    for call <- [:write_events, :register_event_schema] do
      @call call

      for status <- [400, 401, 404, 409, 413, 429, 503, 507] do
        @status status

        test "is that #{call} was not stored if the server answers with status #{status}" do
          url = start_v1(fn _request -> {@status, "refused\n"} end)

          assert {:error, %DbApiError{status: @status}} = run(@call, client(url))
        end
      end

      for status <- [500, 502, 504] do
        @status status

        test "is unknown for #{call} if the server answers with status #{status}" do
          url = start_v1(fn _request -> {@status, "failed\n"} end)

          assert {:error, %OutcomeUnknown{cause: %DbApiError{status: @status}}} =
                   run(@call, client(url))
        end
      end

      test "is that #{call} was not stored if the connection can not be established" do
        assert {:error, %TransmissionError{reason: %{reason: :econnrefused}}} =
                 run(@call, client(closed_url()))
      end

      test "is unknown for #{call} if the connection breaks after it was established" do
        url = start_v1(fn _request -> :close end)

        assert {:error, %OutcomeUnknown{cause: %TransmissionError{reason: %{reason: :closed}}}} =
                 run(@call, client(url))
      end

      test "is unknown for #{call} if the connection stalls" do
        url = start_v1(fn _request -> :silent end)

        assert {:error, %OutcomeUnknown{cause: %ConnectionStalled{}}} =
                 run(@call, client(url, stall_timeout: 200))
      end

      test "is unknown for #{call} if the answer is not from EventSourcingDB" do
        url = start_v1(fn _request -> {200, [{"server", "nginx"}], "[]"} end)

        assert {:error, %OutcomeUnknown{cause: %InvalidServerHeader{}}} =
                 run(@call, client(url))
      end

      test "is unknown for #{call} if the answer is not valid JSON" do
        url = start_v1(fn _request -> {200, "not json"} end)

        assert {:error, %OutcomeUnknown{cause: %TransmissionError{reason: %Jason.DecodeError{}}}} =
                 run(@call, client(url))
      end
    end
  end

  describe "the rate limit" do
    test "tells how many seconds to wait" do
      url = start_v1(fn _request -> {429, [{"retry-after", "7"}], "too many requests"} end)

      assert {:error, %DbApiError{status: 429, retry_after: 7, description: "too many requests"}} =
               EventSourcingDB.write_events(client(url), [candidate()])
    end

    test "tells nothing about waiting without a Retry-After header" do
      url = start_v1(fn _request -> {429, "too many requests"} end)

      assert {:error, %DbApiError{status: 429, retry_after: nil}} =
               EventSourcingDB.read_event_type(client(url), "io.eventsourcingdb.test")
    end

    test "is the only reason to tell how many seconds to wait" do
      url = start_v1(fn _request -> {503, [{"retry-after", "7"}], "unavailable\n"} end)

      assert {:error, %DbApiError{status: 503, retry_after: nil}} =
               EventSourcingDB.read_event_type(client(url), "io.eventsourcingdb.test")
    end

    test "is never retried, not even for a ping, which Req retries otherwise" do
      url = start_v1(fn _request -> {429, "too many requests"} end)

      assert {:error, %DbApiError{status: 429}} = EventSourcingDB.ping(client(url))
      assert pings_received() == 1
    end
  end

  describe "reading subjects" do
    test "reads recursively from the subject, and keeps the subject alone if it does not read recursively" do
      client = serve_subjects(["/books", "/books/42", "/books/42/pages", "/books/43"])

      {result, _elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_subjects!(client, "/books", %ReadSubjectsOptions{recursive: false})
          |> Enum.to_list()
        end)

      assert result == {:ok, ["/books"]}
      assert_receive {:stream_server, :request, "POST /api/v1/read-subjects HTTP/1.1", body}
      assert Jason.decode!(body) == %{"baseSubject" => "/books"}
    end

    test "keeps every subject if it reads recursively" do
      subjects = ["/books", "/books/42", "/books/42/pages", "/books/43"]
      client = serve_subjects(subjects)

      {result, _elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_subjects!(client, "/books", %ReadSubjectsOptions{recursive: true})
          |> Enum.to_list()
        end)

      assert result == {:ok, subjects}
      assert_receive {:stream_server, :request, "POST /api/v1/read-subjects HTTP/1.1", body}
      assert Jason.decode!(body) == %{"baseSubject" => "/books"}
    end
  end

  defp serve_subjects(subjects) do
    StreamServer.start(fn socket ->
      StreamServer.send_head(socket)

      for subject <- subjects do
        StreamServer.send_line(socket, %{
          "type" => "subject",
          "payload" => %{"subject" => subject}
        })
      end

      StreamServer.send_end(socket)
    end)
  end

  defp run(:write_events, client), do: EventSourcingDB.write_events(client, [candidate()])

  defp run(:register_event_schema, client) do
    EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{"type" => "object"})
  end

  defp run(:read_event_type, client),
    do: EventSourcingDB.read_event_type(client, "io.eventsourcingdb.test")

  defp run(:read_events, client), do: EventSourcingDB.read_events(client, "/test")

  # Starts a server without the v2 API, which answers the v2 ping as
  # EventSourcingDB 1.2 does, and every other request as the handler says.
  defp start_v1(handler) do
    FakeServer.start(fn
      %{method: "GET", path: "/api/v2/system/ping"} -> {404, "404 page not found\n"}
      request -> handler.(request)
    end)
  end

  defp client(url, options \\ []) do
    Client.new([base_url: url, api_token: "secret"] ++ options)
  end

  # A URL on which nobody accepts a connection.
  defp closed_url() do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    "http://127.0.0.1:#{port}"
  end

  # Every attempt to ping has arrived once the ping returns, since Req makes
  # its retries before it returns.
  defp pings_received(count \\ 0) do
    receive do
      {:fake_server, :request, %{path: "/api/v1/ping"}} -> pings_received(count + 1)
    after
      0 -> count
    end
  end

  defp candidate(), do: create_test_eventcandidate("/test", %{"value" => 1})
end
