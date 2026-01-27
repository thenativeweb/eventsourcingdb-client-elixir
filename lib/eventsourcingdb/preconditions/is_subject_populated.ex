defmodule Eventsourcingdb.Preconditions.IsSubjectPopulated do
  @enforce_keys [:subject]
  defstruct [:subject]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isSubjectPopulated", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
