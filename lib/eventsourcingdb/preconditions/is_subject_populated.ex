defmodule EventSourcingDB.IsSubjectPopulated do
  @moduledoc """
  Precondition for writing events to ensure the subject **already has at
  least one event**

  Useful when you want to update or modify an existing subject.

  With `options` whose `recursive` is `true` (see
  `EventSourcingDB.PreconditionOptions`), an event of a subject nested under
  the subject suffices as well.
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
          "type" => "isSubjectPopulated",
          "payload" =>
            PreconditionOptions.add_to_payload(%{"subject" => value.subject}, value.options)
        },
        opts
      )
    end
  end
end
