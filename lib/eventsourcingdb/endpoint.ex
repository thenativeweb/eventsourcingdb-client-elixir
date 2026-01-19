defmodule EventSourcingDB.Endpoint do
  @callback path() :: String.t()
  @callback method() :: :get | :post
end
