defmodule EventSourcingDB.IsEventQLQueryTrue do
  @moduledoc """
  Precondition for writing events based on an
  [EventQL](https://docs.eventsourcingdb.io/reference/eventql/) query.

  Sometimes, you want to ensure that an event is only written if a more complex
  condition holds – for example, if no similar event has ever been recorded
  before. The `IsEventQLQueryTrue` precondition lets you define such conditions
  using EventQL.
  """
  use TypedStruct

  typedstruct do
    field :query, String.t(), enforce: true
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"type" => "isEventQlQueryTrue", "payload" => Map.from_struct(value)},
        opts
      )
    end
  end
end
