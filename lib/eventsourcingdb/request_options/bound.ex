defmodule Eventsourcingdb.BoundOptions do
  @moduledoc """
  Reading events within a specific range.

  You can use the `lower_bound` and `upper_bound` parameters (individually or
  together) to limit the result. Both bounds can be configured to be `:inclusive`
  or `:exclusive`.
  """
  use TypedStruct

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
