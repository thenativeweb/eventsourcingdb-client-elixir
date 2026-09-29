defmodule EventSourcingDBTest.TestContainer do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_port(4000)
  )

  test "starts with a custom port", %{esdb: esdb} do
    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end
end
