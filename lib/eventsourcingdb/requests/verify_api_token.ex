defmodule Eventsourcingdb.Requests.VerifyApiToken do
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest

  method :post
  path "/api/v1/verify-api-token"

  @derive Jason.Encoder
  defstruct []

  def validate_response({:ok, %{status: 401}}), do: {:error, :api_token_invalid}
  def validate_response(response), do: super(response)

  def validate_body(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: {:ok, nil}
end
