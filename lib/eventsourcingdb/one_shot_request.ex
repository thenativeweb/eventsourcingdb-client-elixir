defmodule Eventscourcingdb.OneShotRequest do
  @callback validate_response(Req.Response) :: {:ok, any()} | {:error, any()}
end
