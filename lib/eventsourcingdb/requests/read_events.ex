defmodule Eventsourcingdb.Requests.ReadEvents do
  alias Eventsourcingdb.Events.Event
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/read-events"
  type "event"

  typedstruct do
    field :subject, String.t(), enforce: true
    field :options, Eventsourcingdb.Requests.ReadEvents.ReadEventsOptions.t()
  end

  @spec new(String.t()) :: struct()
  def new(subject) do
    struct!(__MODULE__,
      subject: subject
    )
  end

  @spec new(String.t(), Eventsourcingdb.Requests.ReadEvents.ReadEventsOptions.t()) :: struct()
  def new(subject, options) when is_struct(options) do
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

  defmodule ReadEventsOptions do
    typedstruct do
      field :recursive, boolean(), enforce: true
      field :order, :chronological | :antichronological
      field :from_latest_event, Eventsourcingdb.Requests.ReadEvents.FromLatestEventOptions.t()
      field :lower_bound, Eventsourcingdb.Requests.ReadEvents.BoundOptions.t()
      field :upper_bound, Eventsourcingdb.Requests.ReadEvents.BoundOptions.t()
    end

    @spec new(keyword()) :: t()
    def new(options) do
      options =
        options
        |> Keyword.validate!([:recursive, :order, :from_latest_event, :lower_bound, :upper_bound])

      struct!(__MODULE__, options)
    end

    defimpl Jason.Encoder do
      @spec encode(Eventsourcingdb.Requests.ReadEvents.ReadEventsOptions.t(), Jason.Encode.opts()) ::
              iodata()
      def encode(value, opts) do
        Jason.Encode.map(
          %{
            "recursive" => value.recursive,
            "order" => value.order,
            "fromLatestEvent" => value.from_latest_event,
            "lowerBound" => value.lower_bound,
            "upperBound" => value.upper_bound
          }
          |> Map.filter(fn {_k, v} -> not is_nil(v) and v != "" end),
          opts
        )
      end
    end
  end

  defmodule FromLatestEventOptions do
    typedstruct enforce: true do
      field :if_event_is_missing, :read_everything | :read_nothing
      field :subject, String.t()
      field :type, String.t()
    end

    @spec new(keyword()) :: t()
    def new(options) do
      options =
        options
        |> Keyword.validate!([:if_event_is_missing, :subject, :type])

      struct!(__MODULE__, options)
    end

    defimpl Jason.Encoder do
      @spec encode(
              Eventsourcingdb.Requests.ReadEvents.FromLatestEventOptions.t(),
              Jason.Encode.opts()
            ) ::
              iodata()
      def encode(value, opts) do
        Jason.Encode.map(
          %{
            "ifEventIsMissing" =>
              case value.if_event_is_missing do
                :read_everything -> "read-everything"
                :read_nothing -> "read-nothing"
              end,
            "subject" => value.subject,
            "type" => value.type
          },
          opts
        )
      end
    end
  end

  defmodule BoundOptions do
    @derive Jason.Encoder
    typedstruct enforce: true do
      field :id, String.t()
      field :type, :inclusive | :exclusive
    end

    @spec new(keyword()) :: t()
    def new(options) do
      options =
        options
        |> Keyword.validate!([:id, :type])

      struct!(__MODULE__, options)
    end
  end
end
