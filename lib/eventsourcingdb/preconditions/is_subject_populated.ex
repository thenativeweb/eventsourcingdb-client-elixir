defmodule EventSourcingDB.IsSubjectPopulated do
  @moduledoc """
  Precondition for writing events to ensure the subject **already has at
  least one event**

  Useful when you want to update or modify an existing subject.
  """
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
