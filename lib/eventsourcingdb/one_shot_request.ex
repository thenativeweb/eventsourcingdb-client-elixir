defmodule EventSourcingDB.OneShotRequest do
  @moduledoc false
  alias EventSourcingDB.OneShotRequest

  @callback validate_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
              :ok | {:error, Exception.t()}
  @callback validate_body(map()) :: {:ok, any()} | {:error, Exception.t()}
  @callback request_options() :: keyword()

  defmacro __using__(_opts) do
    quote do
      @behaviour OneShotRequest

      @impl OneShotRequest
      def validate_response(_response), do: :ok

      @impl OneShotRequest
      def validate_body(_payload), do: {:ok, nil}

      # Options for Req that the request needs, on top of those of the client.
      @impl OneShotRequest
      def request_options(), do: []

      defoverridable OneShotRequest
    end
  end
end
