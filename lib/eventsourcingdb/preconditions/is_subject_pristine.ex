defmodule Eventscourcingdb.Preconditions.IsSubjectPristine do
  @enforce_keys [:subject]
  defstruct [:subject]
end

defimpl Jason.Encoder, for: Eventscourcingdb.Preconditions.IsSubjectPristine do
  def encode(value, opts) do
    Jason.Encode.map(
      %{"type" => "isSubjectPristine", "payload" => Map.from_struct(value)},
      opts
    )
  end
end
