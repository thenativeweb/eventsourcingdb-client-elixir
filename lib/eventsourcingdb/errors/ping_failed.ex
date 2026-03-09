# credo:disable-for-lines:1
defmodule Eventsourcingdb.Errors.PingFailed do
  defexception message: "Ping Failed: Eventsourcingdb is not reachable"

  @type t() :: %__MODULE__{message: String.t()}
end
