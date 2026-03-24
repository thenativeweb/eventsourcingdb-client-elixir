defmodule EventSourcingDB.ManagementEvent do
  @moduledoc """
  Representing management events around EventSourcingDB.
  """
  alias EventSourcingDB.ManagementEvent
  use TypedStruct

  @key_mapping %{
    "datacontenttype" => :data_content_type,
    "specversion" => :spec_version
  }

  typedstruct enforce: true do
    field :data, any()
    field :data_content_type, String.t()
    field :id, String.t()
    field :source, String.t()
    field :spec_version, String.t()
    field :subject, String.t()
    field :time, String.t()
    field :type, String.t()
  end

  @spec new(map()) :: ManagementEvent.t()
  def new(value \\ %{}) do
    struct!(
      __MODULE__,
      value
      |> Map.new(fn {k, v} ->
        key = Map.get_lazy(@key_mapping, k, fn -> String.to_existing_atom(k) end)
        {key, v}
      end)
    )
  end
end
