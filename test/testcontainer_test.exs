defmodule EventSourcingDBTest.TestContainer do
  alias EventSourcingDB.TestContainer
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils
  import Testcontainers.ExUnit

  container(
    :esdb,
    test_container()
    |> TestContainer.with_port(4000)
  )

  test "starts with a custom port", %{esdb: esdb} do
    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end
end
