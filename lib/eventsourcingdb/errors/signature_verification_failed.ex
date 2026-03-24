defmodule EventSourcingDB.Errors.SignatureVerificationFailed do
  defexception message: "Signature verification failed"

  @type t() :: %__MODULE__{message: String.t()}
end
