defmodule EventsourcingdbTest.Essentials do
  alias Eventsourcingdb.Client
  alias Eventsourcingdb.TestContainer
  use ExUnit.Case

  import Testcontainers.ExUnit

  container(:esdb, TestContainer.new(), shared: true)

  test "ping", %{esdb: esdb} do
    assert Eventsourcingdb.ping(TestContainer.get_client(esdb)) == :ok
  end

  test "ping unavailable server" do
    client =
      Client.new(base_url: "http://localhost:12345", api_token: "secrettoken", retry: false)

    result = Eventsourcingdb.ping(client)

    assert match?({:error, :transmission_error, _}, result)
  end

  test "verify api token", %{esdb: esdb} do
    assert Eventsourcingdb.verify_api_token(TestContainer.get_client(esdb)) == :ok
  end

  test "verify invalid api token", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    invalid_client = Client.new(client.base_url, "invalidtoken")

    result = Eventsourcingdb.verify_api_token(invalid_client)

    assert match?({:error, :api_token_invalid}, result)
  end
end
