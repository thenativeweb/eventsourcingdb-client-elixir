defmodule Eventsourcingdb.Errors.ApiTokenInvalid do
  defexception message: "Provided API Token is invalid"

  @type t() :: %__MODULE__{message: String.t()}
end
