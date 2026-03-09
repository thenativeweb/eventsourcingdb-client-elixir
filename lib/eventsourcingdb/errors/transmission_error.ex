defmodule Eventsourcingdb.Errors.TransmissionError do
  defexception [:reason]

  @type t() :: %__MODULE__{reason: String.t()}

  def message(exception) do
    "Transmission problem: #{exception.reason}"
  end
end
