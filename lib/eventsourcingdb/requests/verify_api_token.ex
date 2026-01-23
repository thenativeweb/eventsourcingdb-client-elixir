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
  def validate_response({:ok, %{status: 401}}), do: {:error, :api_token_invalid}
  def validate_response(_response), do: :ok

  @impl OneShotRequest
  def validate_body(%{"type" => "io.eventsourcingdb.api.api-token-verified"}), do: {:ok, nil}
end
