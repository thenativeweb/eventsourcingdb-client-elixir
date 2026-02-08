defmodule Eventsourcingdb.StreamRequest do
  @moduledoc false
  alias Eventsourcingdb.StreamRequest

  @callback type() :: String.t()
  @callback process(map()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour StreamRequest
      import StreamRequest

      @impl StreamRequest
      def process(data), do: data

      defoverridable(process: 1)
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
