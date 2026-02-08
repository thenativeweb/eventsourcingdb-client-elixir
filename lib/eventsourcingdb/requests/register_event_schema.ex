defmodule Eventsourcingdb.Requests.RegisterEventSchema do
  alias Eventsourcingdb.Events.ManagementEvent
  alias Eventsourcingdb.Requests.RegisterEventSchema
  alias Eventsourcingdb.{OneShotRequest, Endpoint}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/register-event-schema"

  # region request
  # parameters and serialization

  typedstruct enforce: true do
    field :event_type, String.t()
    field :schema, map()
  end

  @spec new(String.t(), map()) :: RegisterEventSchema.t()
  def new(event_type, schema) do
    ExJsonSchema.Schema.resolve(schema)
    struct!(__MODULE__, event_type: event_type, schema: schema)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"eventType" => value.event_type, "schema" => value.schema}, opts)
    end
  end

  # region response
  # validation and parsing

  def validate_body(%{"type" => "io.eventsourcingdb.api.event-schema-registered"} = body),
    do: {:ok, ManagementEvent.new(body)}

  def validate_body(_payload), do: {:error, :invalid_event_type}
end
