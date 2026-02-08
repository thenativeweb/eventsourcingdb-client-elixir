defmodule Eventsourcingdb.Preconditions.IsSubjectPopulated do
  use TypedStruct

  typedstruct do
    field :subject, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isSubjectPopulated", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
