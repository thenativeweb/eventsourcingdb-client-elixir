defmodule Eventsourcingdb.Events.EventType do
  use TypedStruct

  typedstruct do
    field :event_type, String.t(), enforce: true
    field :is_phantom, boolean(), enforce: true
    field :schema, map()
  end

  def new(value \\ %{}) do
    struct!(
      __MODULE__,
      Map.new(value, fn
        {"isPhantom", value} -> {:is_phantom, value}
        {"eventType", value} -> {:event_type, value}
        {key, value} -> {String.to_existing_atom(key), value}
      end)
    )
  end
end
