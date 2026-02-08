defmodule Eventsourcingdb.IsSubjectOnEventId do
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
