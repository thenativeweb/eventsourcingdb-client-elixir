defmodule EventSourcingDBTest.FailingAdapter do
  @moduledoc false

  # A Req adapter that fails every request with the transport error whose
  # reason the calling process put into its dictionary, without sending
  # anything, and without Finch.
  def run(request) do
    {request, %Req.TransportError{reason: Process.get(__MODULE__)}}
  end
end

defmodule EventSourcingDBTest.WriteOutcome do
  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.{ConnectionStalled, OutcomeUnknown, TransmissionError}
  alias EventSourcingDB.Transport.{ApiVersion, WriteOutcome}
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  # Whether a write was stored depends on when it failed, not on the reason:
  # before it was sent, it was not stored, and after that, it was not stored
  # only if the server refused it.

  @stall_timeout 300

  for api <- [:v1, :v2] do
    @api api

    describe "over the #{api} API" do
      for call <- [:write_events, :register_event_schema] do
        @call call

        # Over the v2 API, the write runs in the relay, whose wait for the
        # answer ends only a moment after the connect timeout, which equals
        # the stall timeout. So the connect timeout is shorter here, so that
        # the relay tells for certain that the write was not sent.
        test "#{call} was not stored if connecting times out, since nothing was sent" do
          client = client(unresponsive_url(), connect_options: [timeout: 100])
          :ok = ApiVersion.remember(client, @api)

          assert {:error, %ConnectionStalled{}} = write(@call, client)
        end
      end
    end
  end

  test "a write over the v1 API was not stored if connecting times out after the stall timeout" do
    client = client(unresponsive_url(), [])
    :ok = ApiVersion.remember(client, :v1)

    assert {:error, %ConnectionStalled{}} = write(:write_events, client)
  end

  # Without Finch, nothing tells when a failure happened, so only the reason
  # is known, which a connection that was established may fail with as well.
  for reason <- [:ehostunreach, :enetunreach, {:tls_alert, {:bad_record_mac, ~c"alert"}}] do
    @reason reason

    test "a write over the v1 API that fails with #{inspect(reason)} may have been stored" do
      client =
        Client.new(
          base_url: "http://127.0.0.1:1",
          api_token: "secret",
          req_options: [adapter: EventSourcingDBTest.FailingAdapter]
        )

      Process.put(EventSourcingDBTest.FailingAdapter, @reason)
      :ok = ApiVersion.remember(client, :v1)

      assert {:error, %OutcomeUnknown{cause: %TransmissionError{reason: %{reason: @reason}}}} =
               write(:write_events, client)

      ApiVersion.forget(client)
    end

    test "a failure with #{inspect(reason)} that a stream raises after the server answered leaves the outcome open" do
      failure = %TransmissionError{reason: %Mint.TransportError{reason: @reason}}

      for api <- [:v1, :v2] do
        assert WriteOutcome.classify({:error, failure}, api) ==
                 {:error, %OutcomeUnknown{cause: failure}}
      end
    end
  end

  test "a failure before the request was sent means that the write was not stored, whatever the reason" do
    failure = %ConnectionStalled{}

    for api <- [:v1, :v2] do
      assert WriteOutcome.classify({:error, {:not_sent, failure}}, api) == {:error, failure}
    end
  end

  defp write(:write_events, client) do
    EventSourcingDB.write_events(client, [create_test_eventcandidate("/test", %{"value" => 1})])
  end

  defp write(:register_event_schema, client) do
    EventSourcingDB.register_event_schema(client, "io.eventsourcingdb.test", %{"type" => "object"})
  end

  defp client(url, req_options) do
    Client.new(
      base_url: url,
      api_token: "secret",
      stall_timeout: @stall_timeout,
      req_options: req_options
    )
  end

  # A URL whose server accepts no further connection, since its queue of
  # connections that wait to be accepted is full, so that connecting to it
  # times out. The test fills the queue until a connection of its own times
  # out.
  defp unresponsive_url() do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, backlog: 1])
    {:ok, port} = :inet.port(listen_socket)
    fill_queue(port, 0)

    url = "http://127.0.0.1:#{port}"
    on_exit(fn -> ApiVersion.forget(Client.new(url, "secret")) end)
    url
  end

  defp fill_queue(_port, 50), do: flunk("Connecting did not time out.")

  defp fill_queue(port, count) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, _socket} -> fill_queue(port, count + 1)
      {:error, :timeout} -> :ok
    end
  end
end
