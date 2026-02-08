defmodule Eventsourcingdb.IsEventQLTrue do
  use TypedStruct

  typedstruct do
    field :query, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isEventQlQueryTrue", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
