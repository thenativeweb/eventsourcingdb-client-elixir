defmodule Eventsourcingdb.Requests.Ping do
  @moduledoc false
  alias Eventsourcingdb.Errors.PingFailed
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

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

  def validate_body(%{"type" => "io.eventsourcingdb.api.ping-received"}), do: {:ok, nil}
  def validate_body(_payload), do: {:error, %PingFailed{}}
end
