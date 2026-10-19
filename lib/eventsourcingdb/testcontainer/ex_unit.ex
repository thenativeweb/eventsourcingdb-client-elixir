defmodule EventSourcingDB.TestContainer.ExUnit do
  @moduledoc """
  Starts an `EventSourcingDB.TestContainer` for ExUnit tests, as the
  `container` macro of `Testcontainers.ExUnit` does, through
  `EventSourcingDB.TestContainer.start/1`.

  ```elixir
  defmodule YourTest do
    alias EventSourcingDB.TestContainer
    use ExUnit.Case

    import EventSourcingDB.TestContainer.ExUnit

    container(:esdb, TestContainer.new())

    test "ping", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)

      assert EventSourcingDB.ping(client) == :ok
    end
  end
  ```
  """

  @doc """
  Starts a container for each test, or, with `shared: true`, one for all tests
  of the module, hands it to the tests under the given name, and stops it once
  they are done.

  If the container fails to start, the setup raises the
  `EventSourcingDB.Errors.ContainerStartFailed` that
  `EventSourcingDB.TestContainer.start/1` returns.

  ## Options

  - `:shared` - Whether all tests of the module share a single container,
    `false` by default
  """
  defmacro container(name, config, options \\ []) do
    run_block =
      quote do
        container =
          case EventSourcingDB.TestContainer.start(unquote(config)) do
            {:ok, container} -> container
            {:error, error} -> raise error
          end

        ExUnit.Callbacks.on_exit(fn -> EventSourcingDB.TestContainer.stop(container) end)
        {:ok, %{unquote(name) => container}}
      end

    case Keyword.get(options, :shared, false) do
      true ->
        quote do
          setup_all do
            unquote(run_block)
          end
        end

      _ ->
        quote do
          setup do
            unquote(run_block)
          end
        end
    end
  end
end
