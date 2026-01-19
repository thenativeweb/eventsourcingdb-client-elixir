defmodule Eventscourcingdb.Preconditions.IsEventQLTrue do
  @enforce_keys [:query]
  defstruct [:query]
end

defimpl Jason.Encoder, for: Eventscourcingdb.Preconditions.IsEventQLTrue do
  def encode(value, opts) do
    Jason.Encode.map(
      %{"type" => "isEventQlQueryTrue", "payload" => Map.from_struct(value)},
      opts
    )
  end
end
