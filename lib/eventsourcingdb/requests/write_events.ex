defmodule Eventsourcingdb.Requests.WriteEvents do
  alias Eventsourcingdb.{OneShotRequest, Endpoint, Events.Event}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/write-events"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  typedstruct do
    field :events, Eventsourcingdb.Events.EventCandidate.t()
    field :preconditions, any(), default: []
  end

  def new(events, preconditions \\ []) do
    struct!(__MODULE__, events: events, preconditions: preconditions)
  end

  # region response
  # validation and parsing

  def validate_body(payload) do
    {:ok, Enum.map(payload, fn ev -> Event.new(ev) end)}
  end
end
