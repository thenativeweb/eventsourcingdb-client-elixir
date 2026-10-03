defmodule EventSourcingDB.Errors.HeartbeatTimeout do
  defexception message: "Heartbeat Timeout: No event and no heartbeat arrived for 30 seconds."

  @type t() :: %__MODULE__{message: String.t()}
end
