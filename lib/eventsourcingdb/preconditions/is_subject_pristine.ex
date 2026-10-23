defmodule EventSourcingDB.IsSubjectPristine do
  @moduledoc """
  Precondition for writing events to ensure the subject has no existing events.

  Useful to _introduce_ a subject – it must be the first event and must not
  appear multiple times for the same subject.

  With `options` whose `recursive` is `true` (see
  `EventSourcingDB.PreconditionOptions`), no subject nested under the subject
  may have events either.
  """
  use TypedStruct

  typedstruct do
    field :subject, String.t(), enforce: true
    field :options, EventSourcingDB.PreconditionOptions.t()
  end

  defimpl Jason.Encoder do
    alias EventSourcingDB.PreconditionOptions

    def encode(value, opts) do
      Jason.Encode.map(
        %{
          "type" => "isSubjectPristine",
          "payload" =>
            PreconditionOptions.add_to_payload(%{"subject" => value.subject}, value.options)
        },
        opts
      )
    end
  end
end
