defmodule EventSourcingDBTest.Essentials do
  alias EventSourcingDB.Errors.ApiTokenInvalid
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.Client
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new(), shared: true)

  test "ping", %{esdb: esdb} do
    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
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

    assert match?({:error, %ApiTokenInvalid{}}, result)
  end
end
