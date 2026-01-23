defmodule Eventscourcingdb.OneShotRequest do
  @callback validate_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
              :ok | {:error, any()}
  @callback validate_body(map()) :: {:ok, any()} | {:error, any()}
end
