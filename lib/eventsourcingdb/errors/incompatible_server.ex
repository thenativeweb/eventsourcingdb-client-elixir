defmodule EventSourcingDB.Errors.IncompatibleServer do
  @moduledoc """
  The server does not offer the v2 API, which a precondition on a subject
  needs if its options are anything but `nil` or `recursive` set to `false`,
  such as `recursive` set to `true` (see `EventSourcingDB.PreconditionOptions`).

  If the client SDK remembered that the server does not offer the v2 API, it
  asks the server again before it returns this error, since the server may
  have been upgraded meanwhile. Only if the server still does not offer it,
  the client SDK refuses the write before sending it, so nothing was written.
  """

  defexception message:
                 "Incompatible server: the server does not offer the v2 API, which a recursive precondition needs."

  @type t() :: %__MODULE__{message: String.t()}
end
