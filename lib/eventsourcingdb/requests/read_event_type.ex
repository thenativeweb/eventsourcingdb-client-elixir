defmodule Eventscourcingdb.Requests.ReadEventType do
  alias Eventscourcingdb.OneShotRequest
  alias Eventscourcingdb.Endpoint
  @behaviour Endpoint
  @behaviour OneShotRequest

  @impl Endpoint
  def method(), do: :post

  @impl Endpoint
  def path(), do: "/api/v1/read-event-type"

  @impl OneShotRequest
  def validate_response(_response), do: {:ok, nil}
end
