defmodule Eventsourcingdb.Requests.ReadEventTypes do
  @moduledoc false
  alias Eventsourcingdb.EventType
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/read-event-types"
  type "eventType"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  defstruct []

  # region response
  # validation and parsing

  def process(data), do: EventType.new(data)
end
