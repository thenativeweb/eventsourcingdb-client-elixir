defmodule EventSourcingDB.Errors.InvalidServerHeader do
  defexception message: "Invalid Server Header: No `EventSourcingDB/*` present."

  @type t() :: %__MODULE__{message: String.t()}
end
