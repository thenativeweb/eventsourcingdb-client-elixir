defmodule EventSourcingDB.Errors.MalformedSignature do
  defexception message: "Signature is malformed"

  @type t() :: %__MODULE__{message: String.t()}
end
