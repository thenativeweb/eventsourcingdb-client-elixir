defmodule EventSourcingDB.Errors.TransmissionError do
  defexception [:reason]

  @type t() :: %__MODULE__{reason: Exception.t()}

  def message(exception) do
    "Transmission problem: #{Exception.message(exception.reason)}"
  end
end
