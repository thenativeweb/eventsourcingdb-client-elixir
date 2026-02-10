defmodule Eventsourcingdb.Requests.ObserveEvents do
  @moduledoc false
  alias Eventsourcingdb.Requests.ObserveEvents
  alias Eventsourcingdb.ObserveEventsOptions
  alias Eventsourcingdb.Event
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/observe-events"
  type "event"

  # region request
  # parameters and serialization

  typedstruct do
    field :subject, String.t(), enforce: true
    field :options, ObserveEventsOptions.t()
  end

  @spec new(String.t(), ObserveEventsOptions.t() | nil) :: ObserveEvents.t()
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
