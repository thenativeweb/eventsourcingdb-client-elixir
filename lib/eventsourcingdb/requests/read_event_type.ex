defmodule EventSourcingDB.Requests.ReadEventType do
  alias EventSourcingDB.OneShotRequest
  alias EventSourcingDB.Endpoint
  @behaviour Endpoint
  @behaviour OneShotRequest

  @impl Endpoint
  def method(), do: :post

  @impl Endpoint
  def path(), do: "/api/v1/read-event-type"

  @impl OneShotRequest
  def validate_response(_response), do: {:ok, nil}
end
