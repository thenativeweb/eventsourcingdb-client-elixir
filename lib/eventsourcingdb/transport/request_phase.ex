defmodule EventSourcingDB.Transport.RequestPhase do
  @moduledoc false

  # Tells whether a request that failed was sent at all, from the telemetry
  # events of Finch: a request whose connection failed, before Finch began to
  # send it, was certainly not sent. Everything else may have been sent.
  #
  # Finch sends its events from the process that runs the request: the
  # process that asks for it, if it asks for the whole answer at once, or a
  # process that Finch starts for it, if it streams the answer. So a process
  # that tracks its request is found as the process of an event, or as its
  # parent. Over HTTP/2, the pool sends the events from a process of its own,
  # so there is no evidence, and the request counts as possibly sent.

  use GenServer

  @table __MODULE__
  @handler "eventsourcingdb-request-phase"
  @events [[:finch, :connect, :stop], [:finch, :send, :start]]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Runs the request, and returns its result together with :not_sent if the
  # request was certainly not sent, or :maybe_sent otherwise.
  @spec track((-> result)) :: {result, :not_sent | :maybe_sent} when result: any()
  def track(request) do
    if table?() do
      :ets.insert(@table, {self(), :none})

      try do
        result = request.()
        {result, phase(self())}
      after
        forget(self())
      end
    else
      {request.(), :maybe_sent}
    end
  end

  # Starts to track the requests of the calling process, which then reads the
  # phase with phase/1, for example once it hands the answer on.
  @spec start() :: :ok
  def start() do
    if table?(), do: :ets.insert(@table, {self(), :none})
    :ok
  end

  @spec phase(pid()) :: :not_sent | :maybe_sent
  def phase(pid) do
    case table?() and :ets.lookup(@table, pid) do
      [{^pid, :connect_failed}] -> :not_sent
      _other -> :maybe_sent
    end
  end

  @spec forget(pid()) :: :ok
  def forget(pid) do
    if table?(), do: :ets.delete(@table, pid)
    :ok
  end

  defp table?(), do: :ets.whereis(@table) != :undefined

  #
  # region Telemetry
  #

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    :telemetry.detach(@handler)
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler)
  end

  # A failed connection is evidence that the request was not sent, unless it
  # was sent already, for example by an attempt before a retry. Telemetry
  # detaches a handler that raises, so the handler never does.
  @doc false
  def handle_event([:finch, :connect, :stop], _measurements, %{error: _error}, _config),
    do: mark(:connect_failed)

  def handle_event([:finch, :send, :start], _measurements, _metadata, _config), do: mark(:sent)
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp mark(phase) do
    if table?() and not mark(self(), phase), do: mark(parent(), phase)
    :ok
  rescue
    _error -> :ok
  end

  # Marks the phase of the requests of the process, if it tracks them, and
  # tells whether it does.
  defp mark(nil, _phase), do: false

  defp mark(pid, phase) do
    case :ets.lookup(@table, pid) do
      [{^pid, :sent}] -> true
      [{^pid, _phase}] -> :ets.insert(@table, {pid, phase})
      [] -> false
    end
  end

  defp parent() do
    case Process.info(self(), :parent) do
      {:parent, pid} when is_pid(pid) -> pid
      _other -> nil
    end
  end
end
