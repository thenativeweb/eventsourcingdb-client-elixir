# credo:disable-for-lines:1
defmodule Eventsourcingdb.Errors.ApiError do
  defexception [:reason]

  @type t() :: %__MODULE__{reason: String.t()}

  def message(exception) do
    "API Error: #{exception.reason}"
  end
end
