defmodule Eventsourcingdb.Requests.ObserveEvents do
  alias Eventsourcingdb.Events.Event
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/observe-events"
  type "event"

  typedstruct do
    field :subject, String.t(), enforce: true
    field :options, Eventsourcingdb.Requests.ObserveEvents.ObserveEventsOptions.t()
  end

  @spec new(String.t(), Eventsourcingdb.Requests.ObserveEvents.ObserveEventsOptions.t() | nil) ::
          struct()
  def new(subject, options \\ nil) do
    struct!(__MODULE__,
      subject: subject,
      options: options
    )
  end

  def process(data), do: Event.new(data)

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

  # region Options

  defmodule ObserveEventsOptions do
    typedstruct do
      field :recursive, boolean(), enforce: true
      field :from_latest_event, Eventsourcingdb.RequestOptions.FromLatestEventOptions.t()
      field :lower_bound, Eventsourcingdb.RequestOptions.BoundOptions.t()
    end

    @spec new(keyword()) :: t()
    def new(options) do
      options =
        options
        |> Keyword.validate!([:recursive, :order, :from_latest_event, :lower_bound, :upper_bound])

      struct!(__MODULE__, options)
    end

    defimpl Jason.Encoder do
      @spec encode(
              Eventsourcingdb.Requests.ObserveEvents.ObserveEventsOptions.t(),
              Jason.Encode.opts()
            ) ::
              iodata()
      def encode(value, opts) do
        Jason.Encode.map(
          %{
            "recursive" => value.recursive,
            "fromLatestEvent" => value.from_latest_event,
            "lowerBound" => value.lower_bound
          }
          |> Map.filter(fn {_k, v} -> not is_nil(v) and v != "" end),
          opts
        )
      end
    end
  end
end
