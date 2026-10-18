defmodule EventSourcingDB.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [EventSourcingDB.Transport.ApiVersion, EventSourcingDB.Transport.RequestPhase],
      strategy: :one_for_one,
      name: EventSourcingDB.Supervisor
    )
  end
end
