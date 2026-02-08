defmodule Eventsourcingdb.BoundOptions do
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
