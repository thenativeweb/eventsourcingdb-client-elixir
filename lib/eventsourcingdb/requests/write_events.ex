defmodule EventSourcingDB.Requests.WriteEvents do
  @moduledoc false
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.{OneShotRequest, Endpoint, Event}

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
    field :events, EventCandidate.t()
    field :preconditions, any(), default: []
  end

  def new(events, preconditions \\ []) do
    struct!(__MODULE__, events: events, preconditions: preconditions)
  end

  # region response
  # validation and parsing

  def validate_body(payload) do
    {:ok, Enum.map(payload, &Event.new/1)}
  end
end
