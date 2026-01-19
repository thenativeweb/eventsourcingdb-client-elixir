defmodule EventSourcingDB.Preconditions.IsSubjectPopulated do
  @enforce_keys [:subject]
  defstruct [:subject]
end

defimpl Jason.Encoder, for: EventSourcingDB.Preconditions.IsSubjectPopulated do
  def encode(value, opts) do
    Jason.Encode.map(
      %{"type" => "isSubjectPopulated", "payload" => Map.from_struct(value)},
      opts
    )
  end
end
