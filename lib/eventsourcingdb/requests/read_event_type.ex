defmodule Eventsourcingdb.Requests.ReadEventType do
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  method :post
  path "/api/v1/read-event-type"

  typedstruct do
    field :event_type, String.t(), enforce: true
  end

  @spec new(String.t()) :: struct()
  def new(event_type) do
    struct!(__MODULE__, event_type: event_type)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"eventType" => value.event_type}, opts)
    end
  end
end
