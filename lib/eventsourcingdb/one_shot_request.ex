defmodule Eventsourcingdb.OneShotRequest do
  alias Eventsourcingdb.OneShotRequest

  @type response(t) :: {:ok, t} | {:error, any()}
  @type resonse :: response(any())

  @callback validate_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
              :ok | {:error, any()}
  @callback validate_body(map()) :: {:ok, any()} | {:error, any()}

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
