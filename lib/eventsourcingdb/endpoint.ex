defmodule Eventsourcingdb.Endpoint do
  alias Eventsourcingdb.Endpoint

  @callback path() :: String.t()
  @callback method() :: :get | :post

  defmacro __using__(_opts) do
    quote do
      @behaviour Endpoint
      import Endpoint

      def new(), do: struct(__MODULE__)
      # defoverridable(defstruct: 1)
      defoverridable(new: 0)
    end
  end

  defmacro method(method) do
    quote do
      @impl Endpoint
      def method() do
        unquote(method)
      end
    end
  end

  defmacro path(path) do
    quote do
      @impl Endpoint
      def path() do
        unquote(path)
      end
    end
  end
end
