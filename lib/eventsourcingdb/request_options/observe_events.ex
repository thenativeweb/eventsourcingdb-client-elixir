defmodule EventSourcingDB.ObserveEventsOptions do
  @moduledoc """
  Observe events filter options
  """
  use TypedStruct

  typedstruct do
    field :recursive, boolean(), enforce: true
    field :from_latest_event, EventSourcingDB.FromLatestEventOptions.t()
    field :lower_bound, EventSourcingDB.BoundOptions.t()
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options =
      options
      |> Keyword.validate!([:recursive, :from_latest_event, :lower_bound])

    struct!(__MODULE__, options)
  end

  defimpl Jason.Encoder do
    @spec encode(EventSourcingDB.ObserveEventsOptions.t(), Jason.Encode.opts()) :: iodata()
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
