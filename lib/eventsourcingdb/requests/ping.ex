defmodule Eventsourcingdb.Requests.Ping do
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest

  method :get
  path "/api/v1/ping"

  @derive Jason.Encoder
  defstruct []

  def validate_body(%{"type" => "io.eventsourcingdb.api.ping-received"}), do: {:ok, nil}
  def validate_body(_payload), do: {:error, :ping_failed}
end
