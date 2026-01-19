defmodule EventSourcingDB.Preconditions.IsSubjectOnEventId do
  @enforce_keys [:subject, :event_id]
  defstruct [:subject, :event_id]
end

defimpl Jason.Encoder, for: EventSourcingDB.Preconditions.IsSubjectOnEventId do
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
