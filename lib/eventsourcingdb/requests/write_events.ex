defmodule Eventscourcingdb.Requests.WriteEvents do
  alias Eventscourcingdb.Events.Event
  alias Eventscourcingdb.OneShotRequest
  alias Eventscourcingdb.Endpoint
  @behaviour Endpoint
  @behaviour OneShotRequest

  @impl Endpoint
  def method(), do: :post

  @impl Endpoint
  def path(), do: "/api/v1/write-events"

  @impl OneShotRequest
  def validate_response(_response), do: :ok

  @impl OneShotRequest
  def validate_body(payload) do
    {:ok, Enum.map(payload, fn ev -> Event.new(ev) end)}
  end
end
