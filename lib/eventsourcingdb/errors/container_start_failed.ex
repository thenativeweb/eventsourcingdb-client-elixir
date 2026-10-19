defmodule EventSourcingDB.Errors.ContainerStartFailed do
  @moduledoc """
  `EventSourcingDB.TestContainer.start/1` failed to start a container in which
  the database became reachable.

  - `:message` - Why the start failed
  - `:cause` - The error of Docker, if Docker failed, or `nil`
  """

  defexception [:message, :cause]

  @type t() :: %__MODULE__{message: String.t(), cause: term()}
end
