defmodule EventSourcingDB.Requests.VerifyApiToken do
  @moduledoc false
  alias EventSourcingDB.Errors.ApiTokenInvalid
  alias EventSourcingDB.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest

  # region metadata

  method :post
  path "/api/v1/verify-api-token"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  defstruct []

  # region response
  # validation and parsing

  def validate_response({:ok, %{status: 401}}), do: {:error, %ApiTokenInvalid{}}
  def validate_response(response), do: super(response)

  def validate_body(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: {:ok, nil}
end
