defmodule Eventsourcingdb.Requests.WriteEvents do
  alias Eventsourcingdb.{OneShotRequest, Endpoint, Events.Event}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  method :post
  path "/api/v1/write-events"

  @derive Jason.Encoder
  typedstruct do
    field :events, Eventsourcingdb.Events.EventCandidate.t()
    field :preconditions, any(), default: []
  end

  def new(events, preconditions \\ []) do
    struct!(__MODULE__, events: events, preconditions: preconditions)
  end

  def validate_body(payload) do
    {:ok, Enum.map(payload, fn ev -> Event.new(ev) end)}
  end
end
