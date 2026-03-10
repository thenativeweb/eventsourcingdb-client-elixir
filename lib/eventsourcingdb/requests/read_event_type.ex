defmodule EventSourcingDB.Requests.ReadEventType do
  @moduledoc false
  alias EventSourcingDB.EventType
  alias EventSourcingDB.Requests.ReadEventType
  alias EventSourcingDB.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/read-event-type"

  # region request
  # parameters and serialization

  typedstruct do
    field :event_type, String.t(), enforce: true
  end

  @spec new(String.t()) :: ReadEventType.t()
  def new(event_type) do
    struct!(__MODULE__, event_type: event_type)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"eventType" => value.event_type}, opts)
    end
  end

  # region response
  # validation and parsing

  def validate_body(payload) do
    {:ok, EventType.new(payload)}
  end
end
