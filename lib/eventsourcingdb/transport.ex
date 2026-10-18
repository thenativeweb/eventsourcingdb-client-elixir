defmodule EventSourcingDB.Transport do
  @moduledoc false

  # The one place that chooses the API through which the client talks to the
  # server. Every call of the client SDK asks for the API here, and then runs
  # on the module that implements EventSourcingDB.Transport.API for it.

  alias EventSourcingDB.Client
  alias EventSourcingDB.Transport.V1

  @spec api(Client.t()) :: {:ok, module()} | {:error, Exception.t()}
  def api(%Client{}), do: {:ok, V1}
end
