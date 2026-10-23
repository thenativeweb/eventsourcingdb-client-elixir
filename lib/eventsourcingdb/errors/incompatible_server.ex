defmodule EventSourcingDB.Errors.IncompatibleServer do
  @moduledoc """
  The server does not offer the v2 API, which a precondition on a subject with
  `recursive` set to `true` needs (see `EventSourcingDB.PreconditionOptions`).
  The client SDK refuses such a write before sending it, so nothing was
  written.
  """

  defexception message:
                 "Incompatible server: the server does not offer the v2 API, which a recursive precondition needs."

  @type t() :: %__MODULE__{message: String.t()}
end
