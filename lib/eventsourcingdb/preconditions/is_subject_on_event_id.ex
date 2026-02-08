defmodule Eventsourcingdb.Preconditions.IsSubjectOnEventId do
  use TypedStruct

  typedstruct do
    field :subject, String.t(), enforce: true
    field :event_id, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isSubjectOnEventId", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
