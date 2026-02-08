defmodule Eventsourcingdb.Requests.VerifyApiToken do
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

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

  def validate_response({:ok, %{status: 401}}), do: {:error, :api_token_invalid}
  def validate_response(response), do: super(response)

  def validate_body(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: {:ok, nil}
end
