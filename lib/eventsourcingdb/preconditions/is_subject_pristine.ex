defmodule Eventsourcingdb.Preconditions.IsSubjectPristine do
  @enforce_keys [:subject]
  defstruct [:subject]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isSubjectPristine", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
