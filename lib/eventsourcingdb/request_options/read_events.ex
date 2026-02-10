defmodule Eventsourcingdb.ReadEventsOptions do
  @moduledoc """
  Read events filter options
  """
  use TypedStruct

  typedstruct do
    field :recursive, boolean(), enforce: true
    field :order, :chronological | :antichronological
    field :from_latest_event, Eventsourcingdb.FromLatestEventOptions.t()
    field :lower_bound, Eventsourcingdb.BoundOptions.t()
    field :upper_bound, Eventsourcingdb.BoundOptions.t()
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options =
      options
      |> Keyword.validate!([:recursive, :order, :from_latest_event, :lower_bound, :upper_bound])

    struct!(__MODULE__, options)
  end

  defimpl Jason.Encoder do
    @spec encode(Eventsourcingdb.ReadEventsOptions.t(), Jason.Encode.opts()) :: iodata()
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
