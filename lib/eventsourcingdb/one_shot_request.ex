defmodule EventSourcingDB.OneShotRequest do
  @moduledoc false
  alias EventSourcingDB.OneShotRequest

  @callback validate_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
              :ok | {:error, Exception.t()}
  @callback validate_body(map()) :: {:ok, any()} | {:error, Exception.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour OneShotRequest

      @impl OneShotRequest
      def validate_response(_response), do: :ok

      @impl OneShotRequest
      def validate_body(_payload), do: {:ok, nil}

      defoverridable OneShotRequest
    end
  end
end
