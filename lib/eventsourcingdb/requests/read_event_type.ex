defmodule Eventsourcingdb.Requests.ReadEventType do
  alias Eventsourcingdb.Events.EventType
  alias Eventsourcingdb.Requests.ReadEventType
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  method :post
  path "/api/v1/read-event-type"

  typedstruct do
    field :event_type, String.t(), enforce: true
  end

  @spec new(String.t()) :: ReadEventType.t()
  def new(event_type) do
    struct!(__MODULE__, event_type: event_type)
  end

  def validate_body(payload) do
    {:ok, EventType.new(payload)}
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"eventType" => value.event_type}, opts)
    end
  end
end
