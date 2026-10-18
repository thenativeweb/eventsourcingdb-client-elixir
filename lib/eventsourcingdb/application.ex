defmodule EventSourcingDB.Application do
  @moduledoc false

  use Application

  alias EventSourcingDB.Transport.{ApiVersion, RequestPhase}

  @impl true
  def start(_type, _args) do
    :ok = RequestPhase.attach()

    Supervisor.start_link([ApiVersion],
      strategy: :one_for_one,
      name: EventSourcingDB.Supervisor
    )
  end

  # The handler of the telemetry events of Finch outlives the processes of
  # the application, so it is detached once the application stops.
  @impl true
  def stop(_state), do: RequestPhase.detach()
end
