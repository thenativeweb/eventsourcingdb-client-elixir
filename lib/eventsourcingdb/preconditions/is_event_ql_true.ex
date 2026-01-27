defmodule Eventsourcingdb.Preconditions.IsEventQLTrue do
  @enforce_keys [:query]
  defstruct [:query]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isEventQlQueryTrue", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
