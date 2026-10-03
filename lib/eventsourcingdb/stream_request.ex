defmodule EventSourcingDB.StreamRequest do
  @moduledoc false
  alias EventSourcingDB.StreamRequest

  @callback type() :: String.t()
  @callback process(map()) :: map()
  @callback heartbeats?() :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour StreamRequest
      import StreamRequest

      @impl StreamRequest
      def process(data), do: data

      @impl StreamRequest
      def heartbeats?(), do: false

      defoverridable(process: 1, heartbeats?: 0)
    end
  end

  defmacro type(type) do
    quote do
      @impl StreamRequest
      def type() do
        unquote(type)
      end
    end
  end
end
