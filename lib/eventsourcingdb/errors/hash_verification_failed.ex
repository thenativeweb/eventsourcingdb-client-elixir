defmodule Eventsourcingdb.Errors.HashVerificationFailed do
  defexception [:expected, :actual]

  @type t() :: %__MODULE__{expected: String.t(), actual: String.t()}

  def message(exception) do
    "Event Hash verification failed. Expected: #{exception.expected}, actual: #{exception.actual}"
  end
end
