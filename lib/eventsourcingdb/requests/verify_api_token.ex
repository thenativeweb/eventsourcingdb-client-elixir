defmodule Eventscourcingdb.Requests.VerifyApiToken do
  alias Eventscourcingdb.OneShotRequest
  alias Eventscourcingdb.Endpoint
  @behaviour Endpoint
  @behaviour OneShotRequest

  @impl Endpoint
  def method(), do: :post

  @impl Endpoint
  def path(), do: "/api/v1/verify-api-token"

  @impl OneShotRequest
  def validate_response(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: {:ok, nil}
  def validate_response(_body), do: {:error, :api_token_invalid}
end
