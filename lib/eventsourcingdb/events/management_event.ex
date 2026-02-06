defmodule Eventsourcingdb.Events.ManagementEvent do
  alias Eventsourcingdb.Events.ManagementEvent
  use TypedStruct

  typedstruct enforce: true do
    field :data, any()
    field :datacontenttype, String.t()
    field :id, String.t()
    field :source, String.t()
    field :specversion, String.t()
    field :subject, String.t()
    field :time, String.t()
    field :type, String.t()
  end

  @spec new(map()) :: ManagementEvent.t()
  def new(value \\ %{}) do
    struct!(__MODULE__, value |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end))
  end
end
