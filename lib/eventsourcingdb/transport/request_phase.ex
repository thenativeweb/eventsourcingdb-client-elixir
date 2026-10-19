defmodule EventSourcingDB.Transport.RequestPhase do
  @moduledoc false

  # Tells whether a request that failed was sent at all, from the telemetry
  # events of Finch: a request whose connection failed, before Finch began to
  # send it, was certainly not sent. Everything else may have been sent.
  #
  # It also tells whether a request that the caller aborted, as a call with a
  # timeout does, had a connection by then. In an HTTP/1 pool, which reports
  # every step of the request, a request that had not got its connection yet
  # was certainly not sent.
  #
  # The phase belongs to the request alone, and lives with the process that
  # asks for it, so that it goes away with that process, and no other request
  # can change it:
  #
  #   * A request with a single answer runs in the process that asks for it,
  #     and so do the events of Finch. The handler keeps the phase in the
  #     dictionary of that process, which no other process writes.
  #   * A stream runs in a process that Finch starts for it, as a child of the
  #     relay, which asks for nothing else. The handler sends the phase from
  #     there to the relay, but only to a parent that waits for it, and the
  #     relay collects it once Finch has answered.
  #
  # Over HTTP/2, the pool sends the events from a process of its own, so
  # there is no evidence, and the request counts as possibly sent.

  @key __MODULE__
  @handler "eventsourcingdb-request-phase"
  @events [
    [:finch, :queue, :start],
    [:finch, :connect, :stop],
    [:finch, :reused_connection],
    [:finch, :send, :start]
  ]

  @spec attach() :: :ok
  def attach() do
    :telemetry.detach(@handler)
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok
  def detach() do
    :telemetry.detach(@handler)
    :ok
  end

  # Runs the request in the calling process, and returns its result together
  # with :not_sent if the request was certainly not sent, or :maybe_sent
  # otherwise.
  @spec track((-> result)) :: {result, :not_sent | :maybe_sent} when result: any()
  def track(request), do: tracking({:own, :none}, request, fn -> Process.get(@key) end)

  # Runs the request, which Finch runs in a process that it starts as a child
  # of the calling process, and returns its result as track/1 does.
  @spec track_child((-> result)) :: {result, :not_sent | :maybe_sent} when result: any()
  def track_child(request) do
    tracking(:child, request, fn -> {:own, collect(:none)} end)
  end

  defp tracking(state, request, phase) do
    previous = Process.put(@key, state)

    try do
      result = request.()
      {result, verdict(phase.())}
    after
      if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  # Tells whether the request that runs in the given process, through track/1
  # or through track_child/1, had a connection by now, for a request that the
  # caller is about to abort. Only an HTTP/1 pool reports every step, as the
  # caller tells, so a request in another pool counts as having one.
  @spec connected?(pid(), boolean()) :: boolean()
  def connected?(pid, reported?) do
    phase =
      case :erlang.process_info(pid, {:dictionary, @key}) do
        {{:dictionary, @key}, {:own, phase}} -> phase
        {{:dictionary, @key}, :child} -> pending_reports(pid)
        _other -> :none
      end

    phase in [:connected, :sent] or (not reported? and phase == :none)
  end

  # The phases that the child of a process reported, which wait in the mailbox
  # of that process until the request returns.
  defp pending_reports(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} ->
        Enum.reduce(messages, :none, fn
          {@key, reported}, phase -> merge(phase, reported)
          _message, phase -> phase
        end)

      nil ->
        :none
    end
  end

  # The child sends its phases before it hands the answer of Finch on, so
  # they are in the mailbox once the request returns.
  defp collect(phase) do
    receive do
      {@key, reported} -> collect(merge(phase, reported))
    after
      0 -> phase
    end
  end

  defp verdict({:own, :connect_failed}), do: :not_sent
  defp verdict(_phase), do: :maybe_sent

  # Once the request was sent, by an attempt before a retry as well, it stays
  # sent, and once it had a connection, it stays connected.
  defp merge(:sent, _phase), do: :sent
  defp merge(_phase, :sent), do: :sent
  defp merge(:connected, _phase), do: :connected
  defp merge(_phase, reported), do: reported

  #
  # region Telemetry
  #

  # Telemetry detaches a handler that raises, so the handler never does. An
  # HTTP/1 pool queues every request for a connection, which it then either
  # reuses or connects anew.
  @doc false
  def handle_event([:finch, :queue, :start], _measurements, _metadata, _config),
    do: mark(:queued)

  def handle_event([:finch, :connect, :stop], _measurements, %{error: _error}, _config),
    do: mark(:connect_failed)

  def handle_event([:finch, :connect, :stop], _measurements, _metadata, _config),
    do: mark(:connected)

  def handle_event([:finch, :reused_connection], _measurements, _metadata, _config),
    do: mark(:connected)

  def handle_event([:finch, :send, :start], _measurements, _metadata, _config), do: mark(:sent)
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp mark(phase) do
    case Process.get(@key) do
      {:own, current} -> Process.put(@key, {:own, merge(current, phase)})
      _other -> report_to_parent(phase)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp report_to_parent(phase) do
    with {:parent, parent} when is_pid(parent) <- Process.info(self(), :parent),
         {{:dictionary, @key}, :child} <- :erlang.process_info(parent, {:dictionary, @key}) do
      send(parent, {@key, phase})
    end
  end
end
