defmodule EventSourcingDB.Transport.ApiVersion do
  @moduledoc false

  # Remembers for each client which API its server offers, and lets the
  # concurrent first requests of a client share a single probe.
  #
  # A client holds an atomics array of one element, which every copy of the
  # client shares, and which goes away with the last of them: 0 while the API
  # is unknown, and 1 or 2 once the probe found the v1 or the v2 API. Only a
  # definitive answer is remembered, so after a probe that failed, the next
  # request probes again.
  #
  # The requests that find the API unknown join here. The first of them gets
  # to probe, and the others wait for its result, which they share, whether
  # it is an API or an error. Should the probing process go down, or raise,
  # before it has a result, the next waiting process probes instead.

  use GenServer

  alias EventSourcingDB.Client

  @versions %{1 => :v1, 2 => :v2}
  @numbers %{v1: 1, v2: 2}

  @type version() :: :v1 | :v2
  @type probe() :: (-> {:ok, version()} | {:error, Exception.t()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Returns the API of the server of the client, and probes for it if it is
  # unknown. A client that was not created with Client.new has nowhere to
  # remember the API, so it probes for every request.
  @spec resolve(Client.t(), probe()) :: {:ok, version()} | {:error, Exception.t()}
  def resolve(%Client{__api_version__: nil}, probe), do: probe.()

  def resolve(%Client{__api_version__: cache}, probe) do
    case known(cache) do
      nil -> join(cache, probe)
      version -> {:ok, version}
    end
  end

  # Remembers the API of the server of the client, as a probe does.
  @spec remember(Client.t(), version()) :: :ok
  def remember(%Client{__api_version__: cache}, version), do: store(cache, version)

  defp known(cache), do: Map.get(@versions, :atomics.get(cache, 1))

  defp store(cache, version), do: :atomics.put(cache, 1, Map.fetch!(@numbers, version))

  defp join(cache, probe) do
    case Process.whereis(__MODULE__) do
      nil ->
        probe_and_remember(cache, probe)

      coordinator ->
        case GenServer.call(coordinator, {:join, cache}, :infinity) do
          :probe -> probe_for_all(coordinator, cache, probe)
          {:shared, result} -> result
        end
    end
  end

  # The probe that ran just before this one joined may have found the API
  # already.
  defp probe_for_all(coordinator, cache, probe) do
    result =
      try do
        case known(cache) do
          nil -> probe_and_remember(cache, probe)
          version -> {:ok, version}
        end
      catch
        kind, reason ->
          GenServer.cast(coordinator, {:abandoned, cache})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    GenServer.cast(coordinator, {:done, cache, result})
    result
  end

  defp probe_and_remember(cache, probe) do
    with {:ok, version} <- probe.() do
      store(cache, version)
      {:ok, version}
    end
  end

  #
  # region Coordinator
  #

  @impl true
  def init(probes), do: {:ok, probes}

  @impl true
  def handle_call({:join, cache}, {pid, _tag} = from, probes) do
    case probes do
      %{^cache => probe} ->
        {:noreply, Map.put(probes, cache, %{probe | waiting: probe.waiting ++ [from]})}

      _none ->
        {:reply, :probe, Map.put(probes, cache, %{monitor: Process.monitor(pid), waiting: []})}
    end
  end

  @impl true
  def handle_cast({:done, cache, result}, probes) do
    case Map.pop(probes, cache) do
      {nil, probes} ->
        {:noreply, probes}

      {probe, probes} ->
        Process.demonitor(probe.monitor, [:flush])
        Enum.each(probe.waiting, &GenServer.reply(&1, {:shared, result}))
        {:noreply, probes}
    end
  end

  def handle_cast({:abandoned, cache}, probes), do: {:noreply, hand_over(probes, cache)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, probes) do
    case Enum.find(probes, fn {_cache, probe} -> probe.monitor == monitor end) do
      {cache, _probe} -> {:noreply, hand_over(probes, cache)}
      nil -> {:noreply, probes}
    end
  end

  # Lets the next waiting process probe, if there is one.
  defp hand_over(probes, cache) do
    case Map.pop(probes, cache) do
      {nil, probes} ->
        probes

      {probe, probes} ->
        Process.demonitor(probe.monitor, [:flush])

        case probe.waiting do
          [] ->
            probes

          [{pid, _tag} = next | waiting] ->
            GenServer.reply(next, :probe)
            Map.put(probes, cache, %{monitor: Process.monitor(pid), waiting: waiting})
        end
    end
  end
end
