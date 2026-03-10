# credo:disable-for-lines:1
defmodule Eventsourcingdb.Errors.DBError do
  defexception [:payload]

  @type t() :: %__MODULE__{payload: any()}

  def message(exception) do
    "DB Error: #{IO.inspect(exception.reason)}"
  end
end
