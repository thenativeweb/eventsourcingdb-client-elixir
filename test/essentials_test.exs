defmodule EventSourcingDBTest.Essentials do
  alias EventSourcingDB.Errors.DbApiError
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.Client
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils

  setup_all do: start_container()

  test "ping", %{esdb: esdb} do
    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end

  test "talks to the server through the API that it offers", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)

    assert EventSourcingDB.Transport.api(client) ==
             {:ok,
              on_api(esdb,
                v1: EventSourcingDB.Transport.V1,
                v2: EventSourcingDB.Transport.V2
              )}
  end

  # The test finds out on its own which API the server offers, and observes
  # every request that the client sends, so that it fails if the client talks
  # to a server with the v2 API through the v1 API, which EventSourcingDB 1.3
  # still serves, or the other way round.
  test "sends every call through the API that the server offers", %{esdb: esdb} do
    client = client_reporting_requests(esdb)
    :ok = EventSourcingDB.Transport.ApiVersion.forget(client)

    assert EventSourcingDB.ping(client) == :ok
    assert EventSourcingDB.verify_api_token(client) == :ok

    assert {:ok, [_event]} =
             EventSourcingDB.write_events(client, [
               create_test_eventcandidate("/test", %{"value" => 1})
             ])

    assert [_event] = EventSourcingDB.read_events!(client, "/test") |> Enum.to_list()
    assert [_type] = EventSourcingDB.read_event_types!(client) |> Enum.to_list()

    assert reported_requests() ==
             on_api(esdb,
               v1: [
                 {:get, "/api/v2/system/ping"},
                 {:get, "/api/v1/ping"},
                 {:post, "/api/v1/verify-api-token"},
                 {:post, "/api/v1/write-events"},
                 {:post, "/api/v1/read-events"},
                 {:post, "/api/v1/read-event-types"}
               ],
               v2: [
                 {:get, "/api/v2/system/ping"},
                 {:get, "/api/v2/system/ping"},
                 {:post, "/api/v2/system/verify-token"},
                 {:post, "/api/v2/data/write-events"},
                 {:query, "/api/v2/data/read-events"},
                 {:query, "/api/v2/data/read-event-types"}
               ]
             )
  end

  test "ping unavailable server" do
    client =
      Client.new(
        base_url: "http://localhost:12345",
        api_token: "secrettoken",
        req_options: [retry: false]
      )

    result = EventSourcingDB.ping(client)

    assert match?({:error, %TransmissionError{}}, result)
  end

  test "verify api token", %{esdb: esdb} do
    assert EventSourcingDB.verify_api_token(TestContainer.get_client(esdb)) == :ok
  end

  test "verify invalid api token", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    invalid_client = Client.new(client.base_url, "invalidtoken")

    result = EventSourcingDB.verify_api_token(invalid_client)

    assert {:error, %DbApiError{status: 401, code: nil}} = result
  end

  # Returns the client of the container, which sends the method and the path
  # of every request to the calling process as {:request, method, path}.
  defp client_reporting_requests(container) do
    test_process = self()

    report_request = fn req ->
      Req.Request.append_request_steps(req,
        report_request: fn request ->
          send(test_process, {:request, request.method, request.url.path})
          request
        end
      )
    end

    client = TestContainer.get_client(container)
    %{client | req_options: client.req_options ++ [plugins: [report_request]]}
  end

  defp reported_requests(requests \\ []) do
    receive do
      {:request, method, path} -> reported_requests([{method, path} | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end
end
