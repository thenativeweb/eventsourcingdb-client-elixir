defmodule EventSourcingDB.Errors.PingFailed do
  defexception message: "Ping Failed: EventSourcingDB is not reachable"

  @type t() :: %__MODULE__{message: String.t()}
end
