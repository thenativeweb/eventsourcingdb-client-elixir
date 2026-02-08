defmodule Eventsourcingdb.ObserveEventsOptions do
  use TypedStruct

  typedstruct do
    field :recursive, boolean(), enforce: true
    field :from_latest_event, Eventsourcingdb.FromLatestEventOptions.t()
    field :lower_bound, Eventsourcingdb.BoundOptions.t()
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options =
      options
      |> Keyword.validate!([:recursive, :order, :from_latest_event, :lower_bound, :upper_bound])

    struct!(__MODULE__, options)
  end

  defimpl Jason.Encoder do
    @spec encode(Eventsourcingdb.ObserveEventsOptions.t(), Jason.Encode.opts()) :: iodata()
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
