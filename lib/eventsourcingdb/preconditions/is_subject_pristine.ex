defmodule Eventsourcingdb.IsSubjectPristine do
  @moduledoc """
  Precondition for writing events to ensure the subject has no existing events.

  Useful to _introduce_ a subject – it must be the first event and must not
  appear multiple times for the same subject.
  """
  use TypedStruct

  typedstruct do
    field :subject, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isSubjectPristine", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
