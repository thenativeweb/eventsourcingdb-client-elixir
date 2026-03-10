defmodule EventSourcingDB.Errors.InvalidEventType do
  defexception message: "Invalid Event Type"

  @type t() :: %__MODULE__{message: String.t()}
end
