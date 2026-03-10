defmodule EventSourcingDB.Errors.DBError do
  defexception [:payload]

  @type t() :: %__MODULE__{payload: any()}

  def message(exception) do
    "DB Error: #{inspect(exception.payload)}"
  end
end
