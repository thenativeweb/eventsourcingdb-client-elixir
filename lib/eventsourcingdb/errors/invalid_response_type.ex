defmodule Eventsourcingdb.Errors.InvalidResponseType do
  defexception [:expected, :actual]

  @type t() :: %__MODULE__{expected: String.t(), actual: String.t()}

  def message(exception) do
    "Invalid response type. Expected: #{exception.expected}, actual: #{exception.actual}"
  end
end
