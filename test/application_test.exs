defmodule EventSourcingDBTest.Application do
  # These tests stop the application of the client SDK, which every client
  # shares, so they do not run concurrently with others.
  use ExUnit.Case, async: false

  test "detaches its handler of the telemetry events of Finch once it stops" do
    assert our_handlers() != []

    :ok = Application.stop(:eventsourcingdb)
    stopped = our_handlers()
    {:ok, _apps} = Application.ensure_all_started(:eventsourcingdb)

    assert stopped == []
    assert our_handlers() != []
  end

  defp our_handlers() do
    for handler <- :telemetry.list_handlers([:finch]),
        handler.id == "eventsourcingdb-request-phase",
        do: handler
  end
end
