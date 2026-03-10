defmodule EventSourcingDB.Requests.ReadEvents do
  @moduledoc false
  alias EventSourcingDB.Requests.ReadEvents
  alias EventSourcingDB.ReadEventsOptions
  alias EventSourcingDB.Event
  alias EventSourcingDB.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/read-events"
  type "event"

  # region request
  # parameters and serialization

  typedstruct do
    field :subject, String.t(), enforce: true
    field :options, ReadEventsOptions.t()
  end

  @spec new(String.t(), ReadEventsOptions.t() | nil) :: ReadEvents.t()
  def new(subject, options \\ nil) do
    struct!(__MODULE__,
      subject: subject,
      options: options
    )
  end

  defimpl Jason.Encoder do
    def encode(value, opts) when is_nil(value.options) do
      Jason.Encode.map(
        %{"subject" => value.subject},
        opts
      )
    end

    def encode(value, opts) do
      Jason.Encode.map(
        %{"subject" => value.subject, "options" => value.options},
        opts
      )
    end
  end

  # region response
  # validation and parsing

  def process(data), do: Event.new(data)
end
