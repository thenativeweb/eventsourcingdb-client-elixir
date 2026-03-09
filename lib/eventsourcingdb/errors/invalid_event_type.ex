# credo:disable-for-lines:1
defmodule Eventsourcingdb.Errors.InvalidEventType do
  defexception message: "Invalid Event Type"

  @type t() :: %__MODULE__{message: String.t()}
end
