defmodule EventSourcingDBTest.ApiV2 do
  alias EventSourcingDB.{Client, ErrorCode, Event, EventCandidate, EventType, ManagementEvent}

  alias EventSourcingDB.Errors.{
    ConnectionStalled,
    DbApiError,
    InvalidServerHeader,
    OutcomeUnknown,
    TransmissionError
  }

  alias EventSourcingDB.{IsSubjectPristine, ReadEventsOptions, ReadSubjectsOptions}
  alias EventSourcingDB.Transport.HTTP
  alias EventSourcingDBTest.{FakeServer, StreamServer}
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  # The behavior of the client SDK against servers with the v2 API.

  @stall_timeout 300

  @heartbeat %{"type" => "heartbeat", "data" => %{}}
  @end_item %{"type" => "end", "data" => %{}}

  @precondition_violated %{
    "type" => "error",
    "data" => %{
      "code" => "https://docs.eventsourcingdb.io/errors/precondition-violated",
      "description" => "/preconditions/0: precondition isSubjectPristine does not hold",
      "details" => %{"precondition" => 0}
    }
  }

  @store_failed %{
    "type" => "error",
    "data" => %{
      "code" => "https://docs.eventsourcingdb.io/errors/store-failed",
      "description" => "store failed",
      "details" => %{}
    }
  }

  describe "the calls" do
    test "ping with GET on the v2 route" do
      {result, request} =
        run_single(&EventSourcingDB.ping/1, event("io.eventsourcingdb.api.ping-received"))

      assert result == :ok
      assert request == {"GET /api/v2/system/ping HTTP/1.1", ""}
    end

    test "verify the API token with POST on the v2 route, without a body" do
      {result, request} =
        run_single(
          &EventSourcingDB.verify_api_token/1,
          event("io.eventsourcingdb.api.token-verified")
        )

      assert result == :ok
      assert request == {"POST /api/v2/system/verify-token HTTP/1.1", ""}
    end

    test "fail to verify the API token if the server answers with another event" do
      {result, _request} =
        run_single(
          &EventSourcingDB.verify_api_token/1,
          event("io.eventsourcingdb.api.api-token-verified")
        )

      assert {:error, %EventSourcingDB.Errors.InvalidEventType{}} = result
    end

    test "read an event type with QUERY on the v2 route" do
      data = %{
        "type" => "io.eventsourcingdb.test",
        "hasEvents" => false,
        "schema" => %{"type" => "object"}
      }

      {result, request} =
        run_single(&EventSourcingDB.read_event_type(&1, "io.eventsourcingdb.test"), %{
          "type" => "eventType",
          "data" => data
        })

      assert result ==
               {:ok,
                %EventType{
                  type: "io.eventsourcingdb.test",
                  has_events: false,
                  schema: %{"type" => "object"}
                }}

      assert {"QUERY /api/v2/data/read-event-type HTTP/1.1", body} = request
      assert Jason.decode!(body) == %{"type" => "io.eventsourcingdb.test"}
    end

    test "write events with POST on the v2 route, leaving out what is nil" do
      line = event_line("0", "/books/42")

      {result, request} =
        run_stream(
          fn client ->
            EventSourcingDB.write_events(
              client,
              [
                %EventCandidate{
                  source: "https://library.eventsourcingdb.io",
                  subject: "/books/42",
                  type: "io.eventsourcingdb.test",
                  data: %{"value" => 1}
                },
                %{
                  source: "https://library.eventsourcingdb.io",
                  subject: "/books/43",
                  type: "io.eventsourcingdb.test",
                  data: %{"value" => nil},
                  traceparent: nil
                }
              ],
              [%IsSubjectPristine{subject: "/books/42"}]
            )
          end,
          [@heartbeat, line, @end_item]
        )

      assert {:ok, [%Event{id: "0", subject: "/books/42", traceparent: nil} = event]} = result
      assert event.__raw_data__ == ~s({"value":"0"})
      assert {"POST /api/v2/data/write-events HTTP/1.1", body} = request

      assert Jason.decode!(body) == %{
               "events" => [
                 %{
                   "source" => "https://library.eventsourcingdb.io",
                   "subject" => "/books/42",
                   "type" => "io.eventsourcingdb.test",
                   "data" => %{"value" => 1}
                 },
                 %{
                   "source" => "https://library.eventsourcingdb.io",
                   "subject" => "/books/43",
                   "type" => "io.eventsourcingdb.test",
                   "data" => %{"value" => nil}
                 }
               ],
               "preconditions" => [
                 %{"type" => "isSubjectPristine", "payload" => %{"subject" => "/books/42"}}
               ]
             }
    end

    test "register an event schema with POST on the v2 route" do
      registered =
        put_in(event("io.eventsourcingdb.api.event-schema-registered"), ["data", "data"], %{
          "type" => "io.eventsourcingdb.test",
          "schema" => %{"type" => "object"}
        })

      {result, request} =
        run_stream(
          &EventSourcingDB.register_event_schema(&1, "io.eventsourcingdb.test", %{
            "type" => "object"
          }),
          [@heartbeat, registered, @end_item]
        )

      assert {:ok,
              %ManagementEvent{type: "io.eventsourcingdb.api.event-schema-registered"} = event} =
               result

      assert event.data == %{
               "type" => "io.eventsourcingdb.test",
               "schema" => %{"type" => "object"}
             }

      assert {"POST /api/v2/data/register-event-schema HTTP/1.1", body} = request

      assert Jason.decode!(body) == %{
               "type" => "io.eventsourcingdb.test",
               "schema" => %{"type" => "object"}
             }
    end

    test "read events with QUERY on the v2 route" do
      {result, request} =
        run_stream(
          &(EventSourcingDB.read_events!(&1, "/books", %ReadEventsOptions{
              recursive: true,
              order: :antichronological
            })
            |> Enum.to_list()),
          [event_line("1", "/books/42"), @heartbeat, event_line("0", "/books/42"), @end_item]
        )

      assert [%Event{id: "1"}, %Event{id: "0"} = event] = result
      assert event.__raw_data__ == ~s({"value":"0"})
      assert {"QUERY /api/v2/data/read-events HTTP/1.1", body} = request

      assert Jason.decode!(body) == %{
               "subject" => "/books",
               "options" => %{"recursive" => true, "order" => "antichronological"}
             }
    end

    test "observe events with QUERY on the v2 route" do
      {result, request} =
        run_stream(
          &(EventSourcingDB.observe_events!(&1, "/books") |> Enum.take(2)),
          [@heartbeat, event_line("0", "/books"), @heartbeat, event_line("1", "/books")],
          finish: false
        )

      assert [%Event{id: "0"}, %Event{id: "1"}] = result
      assert {"QUERY /api/v2/data/observe-events HTTP/1.1", body} = request
      assert Jason.decode!(body) == %{"subject" => "/books"}
    end

    test "run an EventQL query with QUERY on the v2 route, and yield the value of each row" do
      {result, request} =
        run_stream(
          &(EventSourcingDB.run_eventql_query!(&1, "FROM e IN events PROJECT INTO e.id")
            |> Enum.to_list()),
          [row(%{"id" => "0"}), @heartbeat, row(1), row(nil), @end_item]
        )

      assert result == [%{"id" => "0"}, 1, nil]
      assert {"QUERY /api/v2/data/run-eventql-query HTTP/1.1", body} = request
      assert Jason.decode!(body) == %{"query" => "FROM e IN events PROJECT INTO e.id"}
    end

    for recursive <- [true, false] do
      @recursive recursive

      test "read subjects with QUERY on the v2 route, with recursive set to #{recursive}" do
        {result, request} =
          run_stream(
            &(EventSourcingDB.read_subjects!(&1, "/books", %ReadSubjectsOptions{
                recursive: @recursive
              })
              |> Enum.to_list()),
            [subject("/books"), @heartbeat, subject("/books/42"), @end_item]
          )

        assert result == ["/books", "/books/42"]
        assert {"QUERY /api/v2/data/read-subjects HTTP/1.1", body} = request

        assert Jason.decode!(body) == %{
                 "subject" => "/books",
                 "options" => %{"recursive" => @recursive}
               }
      end
    end

    test "read event types with QUERY on the v2 route, without a body" do
      {result, request} =
        run_stream(
          &(EventSourcingDB.read_event_types!(&1) |> Enum.to_list()),
          [
            %{
              "type" => "eventType",
              "data" => %{"type" => "io.eventsourcingdb.a", "hasEvents" => true, "schema" => nil}
            },
            @heartbeat,
            %{
              "type" => "eventType",
              "data" => %{
                "type" => "io.eventsourcingdb.b",
                "hasEvents" => false,
                "schema" => %{"type" => "object"}
              }
            },
            @end_item
          ]
        )

      assert result == [
               %EventType{type: "io.eventsourcingdb.a", has_events: true, schema: nil},
               %EventType{
                 type: "io.eventsourcingdb.b",
                 has_events: false,
                 schema: %{"type" => "object"}
               }
             ]

      assert request == {"QUERY /api/v2/data/read-event-types HTTP/1.1", ""}
    end
  end

  describe "a stream" do
    for name <- [:read_events, :run_eventql_query, :read_subjects, :read_event_types] do
      @name name

      test "of #{name} fails if it ends without its end item" do
        {result, _request} = run_stream(&(read(@name, &1) |> Enum.to_list()), [@heartbeat])

        assert result == {:raised, HTTP.broken_off_error()}
      end

      test "of #{name} ends with its end item, even if the response goes on" do
        {result, _request} =
          run_stream(&(read(@name, &1) |> Enum.to_list()), [@heartbeat, @end_item], finish: false)

        assert result == []
      end
    end

    test "of observing events fails if the server ends it without an error" do
      {result, _request} =
        run_stream(&(EventSourcingDB.observe_events!(&1, "/books") |> Enum.to_list()), [
          event_line("0", "/books")
        ])

      assert result == {:raised, HTTP.broken_off_error()}
    end

    test "raises an error that the server reports, with its code and details" do
      {result, _request} =
        run_stream(
          &(EventSourcingDB.read_events!(&1, "/books") |> Enum.to_list()),
          [event_line("0", "/books"), @precondition_violated, @end_item]
        )

      assert result ==
               {:raised,
                %DbApiError{
                  code: ErrorCode.precondition_violated(),
                  description: "/preconditions/0: precondition isSubjectPristine does not hold",
                  details: %{"precondition" => 0},
                  status: 200
                }}
    end

    test "fails to open with the text of an error response" do
      url = start_v2(fn _request -> {400, "/options/recursive: null is not allowed\n"} end)

      assert EventSourcingDB.read_events(client(url), "/books") ==
               {:error,
                %DbApiError{status: 400, description: "/options/recursive: null is not allowed\n"}}
    end

    test "fails to open with the seconds to wait that the rate limit tells" do
      url = start_v2(fn _request -> {429, [{"retry-after", "3"}], "too many requests"} end)

      assert {:error, %DbApiError{status: 429, retry_after: 3, code: nil}} =
               EventSourcingDB.read_events(client(url), "/books")
    end
  end

  describe "a request with a single answer" do
    test "fails with an error that the server reports at status 200" do
      url =
        start_v2(fn _request ->
          {200,
           Jason.encode!(%{
             "type" => "error",
             "data" => %{
               "code" => "https://docs.eventsourcingdb.io/errors/event-type-unknown",
               "description" => "event type is unknown",
               "details" => %{"value" => "io.eventsourcingdb.test"}
             }
           })}
        end)

      assert EventSourcingDB.read_event_type(client(url), "io.eventsourcingdb.test") ==
               {:error,
                %DbApiError{
                  code: ErrorCode.event_type_unknown(),
                  description: "event type is unknown",
                  details: %{"value" => "io.eventsourcingdb.test"},
                  status: 200
                }}
    end

    test "fails with the status of a transport error, and its text" do
      url = start_v2(fn _request -> {401, "unauthorized\n"} end)

      assert EventSourcingDB.verify_api_token(client(url)) ==
               {:error, %DbApiError{status: 401, description: "unauthorized\n"}}
    end

    test "fails with the seconds to wait that the rate limit tells" do
      url = start_v2(fn _request -> {429, [{"retry-after", "2"}], "too many requests"} end)

      assert {:error, %DbApiError{status: 429, retry_after: 2}} =
               EventSourcingDB.read_event_type(client(url), "io.eventsourcingdb.test")
    end
  end

  describe "the outcome of a write" do
    for call <- [:write_events, :register_event_schema] do
      @call call

      test "is that #{call} was not stored if the server reports an error other than store-failed" do
        url =
          start_v2(fn _request -> {:lines, [@heartbeat, @precondition_violated, @end_item]} end)

        assert {:error, %DbApiError{status: 200, code: code}} = write(@call, client(url))
        assert code == ErrorCode.precondition_violated()
      end

      test "is unknown for #{call} if the server reports store-failed" do
        url = start_v2(fn _request -> {:lines, [@heartbeat, @store_failed, @end_item]} end)

        assert {:error, %OutcomeUnknown{cause: %DbApiError{status: 200, code: code}}} =
                 write(@call, client(url))

        assert code == ErrorCode.store_failed()
      end

      for status <- [400, 401, 408, 413, 429, 503] do
        @status status

        test "is that #{call} was not stored if the server answers with status #{status}" do
          url = start_v2(fn _request -> {@status, "refused\n"} end)

          assert {:error, %DbApiError{status: @status, code: nil}} = write(@call, client(url))
        end
      end

      for status <- [404, 405, 500, 502, 504, 507] do
        @status status

        test "is unknown for #{call} if the server answers with status #{status}" do
          url = start_v2(fn _request -> {@status, "failed\n"} end)

          assert {:error, %OutcomeUnknown{cause: %DbApiError{status: @status}}} =
                   write(@call, client(url))
        end
      end

      test "is that #{call} was not stored if the connection can not be established" do
        client = client(closed_url())
        :ok = EventSourcingDB.Transport.ApiVersion.remember(client, :v2)

        assert {:error, %TransmissionError{reason: %{reason: :econnrefused}}} =
                 write(@call, client)
      end

      test "is unknown for #{call} if the connection breaks after it was established" do
        url = start_v2(fn _request -> :close end)

        assert {:error, %OutcomeUnknown{cause: %TransmissionError{}}} = write(@call, client(url))
      end

      test "is unknown for #{call} if the connection stalls before the answer begins" do
        url = start_v2(fn _request -> :silent end)

        assert {:error, %OutcomeUnknown{cause: %ConnectionStalled{}}} =
                 write(@call, client(url, stall_timeout: @stall_timeout))
      end

      test "is unknown for #{call} if the connection stalls after a heartbeat" do
        {result, _request} = run_stream(&write(@call, &1), [@heartbeat], finish: false)

        assert {:error, %OutcomeUnknown{cause: %ConnectionStalled{}}} = result
      end

      test "is unknown for #{call} if the stream ends without its end item" do
        {result, _request} = run_stream(&write(@call, &1), [@heartbeat])

        assert result == {:error, %OutcomeUnknown{cause: HTTP.broken_off_error()}}
      end

      test "is unknown for #{call} if the answer is not from EventSourcingDB" do
        url = start_v2(fn _request -> {200, [{"server", "nginx"}], ""} end)

        assert {:error, %OutcomeUnknown{cause: %InvalidServerHeader{}}} =
                 write(@call, client(url))
      end

      test "is unknown for #{call} if the answer is not valid JSON" do
        url =
          start_v2(fn _request ->
            {200, [{"content-type", "application/x-ndjson"}], "not json\n"}
          end)

        assert {:error, %OutcomeUnknown{cause: %Jason.DecodeError{}}} = write(@call, client(url))
      end
    end
  end

  defp read(:read_events, client), do: EventSourcingDB.read_events!(client, "/books")

  defp read(:run_eventql_query, client),
    do: EventSourcingDB.run_eventql_query!(client, "FROM e IN events PROJECT INTO e")

  defp read(:read_subjects, client),
    do: EventSourcingDB.read_subjects!(client, "/", %ReadSubjectsOptions{recursive: true})

  defp read(:read_event_types, client), do: EventSourcingDB.read_event_types!(client)

  defp write(:write_events, client) do
    EventSourcingDB.write_events(client, [create_test_eventcandidate("/test", %{"value" => 1})])
  end

  defp write(:register_event_schema, client) do
    EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{"type" => "object"})
  end

  # Runs the call against a stream server with the v2 API, which answers with
  # the given envelope as a single answer, and returns the result together
  # with the request line and the body of the request.
  defp run_single(call, envelope) do
    client =
      StreamServer.start(
        fn socket ->
          StreamServer.send_head(socket, 200, [
            {"server", "EventSourcingDB/test"},
            {"content-type", "application/json"}
          ])

          StreamServer.send_data(socket, Jason.encode!(envelope))
          StreamServer.send_end(socket)
        end,
        api: :v2,
        stall_timeout: @stall_timeout
      )

    {{:ok, result}, _elapsed} = StreamServer.run_with_guard(fn -> call.(client) end)
    {result, received_request()}
  end

  # Runs the call against a stream server with the v2 API, which answers with
  # the given items as NDJSON lines, and then ends the response, unless the
  # finish option is false, and returns what the call returned or raised,
  # together with the request line and the body of the request.
  defp run_stream(call, items, options \\ []) do
    client =
      StreamServer.start(
        fn socket ->
          StreamServer.send_head(socket)
          Enum.each(items, &StreamServer.send_line(socket, &1))

          if Keyword.get(options, :finish, true) do
            StreamServer.send_end(socket)
          end
        end,
        api: :v2,
        stall_timeout: @stall_timeout
      )

    result =
      case StreamServer.run_with_guard(fn -> call.(client) end) do
        {{:ok, result}, _elapsed} -> result
        {{:raised, exception}, _elapsed} -> {:raised, exception}
      end

    {result, received_request()}
  end

  defp received_request() do
    assert_receive {:stream_server, :request, request_line, body}
    {request_line, body}
  end

  # Starts a server with the v2 API, which answers the v2 ping as
  # EventSourcingDB 1.3 does, and every other request as the handler says.
  defp start_v2(handler) do
    FakeServer.start(fn
      %{method: "GET", path: "/api/v2/system/ping"} ->
        {200, [{"content-type", "application/json"}],
         Jason.encode!(event("io.eventsourcingdb.api.ping-received"))}

      request ->
        handler.(request)
    end)
  end

  defp client(url, options \\ []) do
    Client.new([base_url: url, api_token: "secret"] ++ options)
  end

  # A URL on which nobody accepts a connection. A server may listen on its
  # port later on, so the API that a test remembers for it is forgotten after
  # the test.
  defp closed_url() do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    url = "http://localhost:#{port}"
    on_exit(fn -> EventSourcingDB.Transport.ApiVersion.forget(Client.new(url, "secret")) end)
    url
  end

  defp event(type) do
    %{
      "type" => "event",
      "data" => %{
        "specversion" => "1.0",
        "id" => "01a150ce-477b-7636-a58e-d24b5469216c",
        "source" => "https://www.eventsourcingdb.io",
        "type" => type,
        "subject" => "/api/v2/system",
        "time" => "2026-10-18T12:00:00.000000000Z",
        "datacontenttype" => "application/json",
        "data" => %{}
      }
    }
  end

  defp event_line(id, subject) do
    %{
      "type" => "event",
      "data" => %{
        "specversion" => "1.0",
        "id" => id,
        "source" => "https://library.eventsourcingdb.io",
        "subject" => subject,
        "type" => "io.eventsourcingdb.test",
        "time" => "2026-10-18T12:00:00.000000000Z",
        "predecessorhash" => String.duplicate("0", 64),
        "datacontenttype" => "application/json",
        "data" => %{"value" => id},
        "traceparent" => nil,
        "tracestate" => nil,
        "hash" => "esdb:hash:v2:" <> String.duplicate("0", 64),
        "signature" => nil
      }
    }
  end

  defp row(value), do: %{"type" => "row", "data" => %{"value" => value}}
  defp subject(subject), do: %{"type" => "subject", "data" => %{"subject" => subject}}
end
