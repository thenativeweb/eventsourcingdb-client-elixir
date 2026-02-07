defmodule Eventsourcingdb.Requests.ReadEventTypes do
  alias Eventsourcingdb.Events.EventType
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/read-event-types"
  type "eventType"

  @derive Jason.Encoder
  defstruct []

  def process(data), do: EventType.new(data)
end
