defmodule EventSourcingDB.Errors.UnsupportedHashVersion do
  defexception [:version]

  @type t() :: %__MODULE__{version: String.t()}

  def message(exception) do
    "Event Hash version is not supported: #{exception.version}"
  end
end
