defmodule Eventsourcingdb.IsSubjectOnEventId do
  @moduledoc """
  Precondition for writing events to ensure the subject alread contains events.

  In this case, you must specify both the subject and the ID of the most recent
  event. This lets you check that no new events have been added since you last
  read the subject – essentially enabling **optimistic locking** on a **per-subject
  basis**.
  """
  use TypedStruct

  typedstruct do
    field :subject, String.t(), enforce: true
    field :event_id, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{
          "type" => "isSubjectOnEventId",
          "payload" => %{
            "subject" => value.subject,
            "eventId" => value.event_id
          }
        },
        opts
      )
    end
  end
end
