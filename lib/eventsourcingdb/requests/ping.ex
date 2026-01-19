defmodule Eventscourcingdb.Requests.Ping do
  alias Eventscourcingdb.OneShotRequest
  alias Eventscourcingdb.Endpoint
  @behaviour Endpoint
  @behaviour OneShotRequest

  @impl Endpoint
  def method(), do: :get

  @impl Endpoint
  def path(), do: "/api/v1/ping"

  @impl OneShotRequest
  def validate_response(%{"type" => "io.eventsourcingdb.api.ping-received"}), do: {:ok, nil}
  def validate_response(_response), do: {:error, :ping_failed}
end
