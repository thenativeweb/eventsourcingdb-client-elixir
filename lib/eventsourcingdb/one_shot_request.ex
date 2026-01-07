defmodule EventSourcingDB.OneShotRequest do
  @callback validate_response(Req.Response) :: {:ok, Req.Response} | {:error, any()}
end
