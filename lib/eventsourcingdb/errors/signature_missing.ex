defmodule EventSourcingDB.Errors.SignatureMissing do
  defexception message: "Signature is missing for the event"

  @type t() :: %__MODULE__{message: String.t()}
end
