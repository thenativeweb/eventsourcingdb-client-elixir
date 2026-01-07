defmodule EventSourcingDB.Endpoint do
  @callback path() :: String.t()
  @callback method() :: atom()
end
