defmodule EventSourcingDB.EventType do
  @moduledoc """
  An event type that EventSourcingDB knows, because events of it were written
  or a schema was registered for it.
  """
  alias EventSourcingDB.EventType
  use TypedStruct

  typedstruct do
    @typedoc """
    An event type as EventSourcingDB returns it.

    - `:type` - The name of the event type

    - `:has_events` - Whether events of this type were written, rather than only its schema registered

    - `:schema` - The registered schema, or `nil` if there is none
    """
    field :type, String.t(), enforce: true
    field :has_events, boolean(), enforce: true
    field :schema, map()
  end

  @doc """
  Creates an event type from its JSON representation, as the server sends it.
  """
  @spec new(map()) :: EventType.t()
  def new(value \\ %{}) do
    struct!(__MODULE__,
      type: value["type"],
      has_events: value["hasEvents"],
      schema: value["schema"]
    )
  end
end
