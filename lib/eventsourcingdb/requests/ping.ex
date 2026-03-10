defmodule EventSourcingDB.Requests.Ping do
  @moduledoc false
  alias EventSourcingDB.Errors.PingFailed
  alias EventSourcingDB.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest

  # region metadata

  method :get
  path "/api/v1/ping"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  defstruct []

  # region response
  # validation and parsing

  def validate_body(%{"type" => "io.EventSourcingDB.api.ping-received"}), do: {:ok, nil}
  def validate_body(_payload), do: {:error, %PingFailed{}}
end
