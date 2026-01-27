defmodule Eventsourcingdb.Preconditions.IsSubjectOnEventId do
  @enforce_keys [:subject, :event_id]
  defstruct [:subject, :event_id]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{
          "type" => "isSubjectOnEventId",
          "payload" => %{"subject" => value["subject"], "eventId" => value["event_id"]}
        },
        opts
      )
    end
  end
end
