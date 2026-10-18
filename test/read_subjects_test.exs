defmodule EventSourcingDBTest.ReadSubjects do
  alias EventSourcingDB.ReadSubjectsOptions
  alias EventSourcingDB.TestContainer
  import EventSourcingDBTest.Utils
  use ExUnit.Case, async: true

  import Testcontainers.ExUnit

  container(:esdb, test_container())

  @recursive %ReadSubjectsOptions{recursive: true}
  @not_recursive %ReadSubjectsOptions{recursive: false}

  test "read no subjects when database is empty", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    result = EventSourcingDB.read_subjects!(client, "/", @recursive)

    assert Enum.empty?(result)
  end

  test "reads all subjects", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    write_test_events(client)

    result = EventSourcingDB.read_subjects!(client, "/", @recursive)

    assert ["/", "/test", "/test/1", "/test/2"] == Enum.to_list(result)
  end

  test "reads all subjects from the given subject", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    write_test_events(client)

    result = EventSourcingDB.read_subjects!(client, "/test", @recursive)

    assert ["/test", "/test/1", "/test/2"] == Enum.to_list(result)
  end

  test "reads the given subject alone if it does not read recursively", %{esdb: esdb} do
    client = TestContainer.get_client(esdb)
    write_test_events(client)

    assert ["/test"] ==
             EventSourcingDB.read_subjects!(client, "/test", @not_recursive) |> Enum.to_list()

    assert ["/test/1"] ==
             EventSourcingDB.read_subjects!(client, "/test/1", @not_recursive) |> Enum.to_list()

    assert [] ==
             EventSourcingDB.read_subjects!(client, "/other", @not_recursive) |> Enum.to_list()
  end

  test "reads the given subject alone as the server normalizes it, with a trailing slash", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)
    write_test_events(client)

    assert ["/test"] ==
             EventSourcingDB.read_subjects!(client, "/test/", @not_recursive) |> Enum.to_list()

    assert ["/"] == EventSourcingDB.read_subjects!(client, "/", @not_recursive) |> Enum.to_list()
  end

  test "refuses to read subjects without options that say whether to read recursively", %{
    esdb: esdb
  } do
    client = TestContainer.get_client(esdb)

    for options <- [nil, [recursive: true], %{recursive: true}, struct(ReadSubjectsOptions, [])] do
      assert_raise ArgumentError, ~r/:recursive/, fn ->
        EventSourcingDB.read_subjects(client, "/", options)
      end

      assert_raise ArgumentError, ~r/:recursive/, fn ->
        EventSourcingDB.read_subjects!(client, "/", options)
      end
    end
  end

  test "creates options only with a recursive option of true or false" do
    assert ReadSubjectsOptions.new(recursive: false) == @not_recursive
    assert ReadSubjectsOptions.new(recursive: true) == @recursive

    for options <- [[], [recursive: nil], [recursive: "yes"]] do
      assert_raise ArgumentError, fn -> ReadSubjectsOptions.new(options) end
    end
  end

  defp write_test_events(client) do
    EventSourcingDB.write_events!(client, [
      create_test_eventcandidate("/test/1", %{"value" => 21}),
      create_test_eventcandidate("/test/2", %{"value" => 42})
    ])
  end
end
