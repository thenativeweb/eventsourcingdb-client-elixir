defmodule Eventsourcingdb.StreamRequest do
  alias Eventsourcingdb.StreamRequest

  @callback type() :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour StreamRequest
      import StreamRequest
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
