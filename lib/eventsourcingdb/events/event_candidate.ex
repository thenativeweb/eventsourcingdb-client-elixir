defmodule Eventsourcingdb.Events.EventCandidate do
  use TypedStruct

  typedstruct do
    field :data, any(), enforce: true
    field :source, String.t(), enforce: true
    field :subject, String.t(), enforce: true
    field :traceparent, String.t()
    field :tracestate, String.t()
    field :type, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        Map.from_struct(value) |> Map.filter(fn {_k, v} -> not is_nil(v) and v != "" end),
        opts
      )
    end
  end
end
