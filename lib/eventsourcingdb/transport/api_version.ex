defmodule EventSourcingDB.Transport.ApiVersion do
  @moduledoc false

  # Remembers which API a server offers, and lets the concurrent first
  # requests to a server share a single probe.
  #
  # The API is a property of the server, so the answer is remembered by the
  # base URL of the client, for every client of that server, in a table that
  # the process of this module owns. Only a definitive answer is remembered,
  # so after a probe that failed, the next request probes again.
  #
  # The requests that find the API unknown join here. The first of them gets
  # to probe, and the others wait for its result, which they share, whether
  # it is an API or an error. Should the probing process go down, or raise,
  # before it has a result, the next waiting process probes instead.
  #
  # A request of a call with a timeout probes on its own, with share: false,
  # so that it neither waits for a probe that its timeout does not bound, nor
  # hands its own timeout on to the requests that would share its probe.
  #
  # A request that can not use the API that is remembered, with stale: set
  # to it, probes again as if the API were unknown, and joins the probe that
  # runs, if any. Every other request keeps using the remembered API
  # meanwhile, rather than wait for a probe that it does not need.

  use GenServer

  alias EventSourcingDB.Client

  @table __MODULE__

  @type version() :: :v1 | :v2
  @type probe() :: (-> {:ok, version()} | {:error, Exception.t()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Returns the API of the server of the client, and probes for it if it is
  # unknown, or if it is the stale one.
  @spec resolve(Client.t(), probe(), keyword()) :: {:ok, version()} | {:error, Exception.t()}
  def resolve(%Client{} = client, probe, options \\ []) do
    server = server(client)
    stale = Keyword.get(options, :stale)

    case {known(server), Keyword.get(options, :share, true)} do
      {version, _share} when version not in [nil, stale] -> {:ok, version}
      {_unknown_or_stale, true} -> join(server, probe, stale)
      {_unknown_or_stale, false} -> probe_and_remember(server, probe)
    end
  end

  # Remembers the API of the server of the client, as a probe does.
  @spec remember(Client.t(), version()) :: :ok
  def remember(%Client{} = client, version), do: store(server(client), version)

  # Forgets the API of the server of the client, so that the next request
  # probes again.
  @spec forget(Client.t()) :: :ok
  def forget(%Client{} = client) do
    if table?(), do: :ets.delete(@table, server(client))
    :ok
  end

  # The server is the base URL that the requests of the client go to, which
  # its Req options may override.
  defp server(%Client{} = client) do
    client.req_options
    |> Keyword.get(:base_url, client.base_url)
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp known(server) do
    with true <- table?(),
         [{^server, version}] <- :ets.lookup(@table, server) do
      version
    else
      _unknown -> nil
    end
  end

  # Without the process of this module, as before the application of the
  # client SDK started, nothing is remembered.
  defp store(server, version) do
    if table?(), do: :ets.insert(@table, {server, version})
    :ok
  end

  defp table?(), do: :ets.whereis(@table) != :undefined

  # A request that waits for the probe of another one probes on its own
  # should the process of this module go down meanwhile, as does a request
  # that finds the process down.
  defp join(server, probe, stale) do
    with coordinator when is_pid(coordinator) <- Process.whereis(__MODULE__),
         {:ok, answer} <- call_join(coordinator, server) do
      case answer do
        :probe -> probe_for_all(coordinator, server, probe, stale)
        {:shared, result} -> result
      end
    else
      _down -> probe_and_remember(server, probe)
    end
  end

  defp call_join(coordinator, server) do
    {:ok, GenServer.call(coordinator, {:join, server}, :infinity)}
  catch
    :exit, _reason -> :down
  end

  # The probe that ran just before this one joined may have found the API
  # already, unless it found the stale one again.
  defp probe_for_all(coordinator, server, probe, stale) do
    result =
      try do
        case known(server) do
          version when version in [nil, stale] -> probe_and_remember(server, probe)
          version -> {:ok, version}
        end
      catch
        kind, reason ->
          GenServer.cast(coordinator, {:abandoned, server})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    GenServer.cast(coordinator, {:done, server, result})
    result
  end

  defp probe_and_remember(server, probe) do
    with {:ok, version} <- probe.() do
      store(server, version)
      {:ok, version}
    end
  end

  #
  # region Coordinator
  #

  @impl true
  def init(probes) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, probes}
  end

  @impl true
  def handle_call({:join, server}, {pid, _tag} = from, probes) do
    case probes do
      %{^server => probe} ->
        {:noreply, Map.put(probes, server, %{probe | waiting: probe.waiting ++ [from]})}

      _none ->
        {:reply, :probe, Map.put(probes, server, %{monitor: Process.monitor(pid), waiting: []})}
    end
  end

  @impl true
  def handle_cast({:done, server, result}, probes) do
    case Map.pop(probes, server) do
      {nil, probes} ->
        {:noreply, probes}

      {probe, probes} ->
        Process.demonitor(probe.monitor, [:flush])
        Enum.each(probe.waiting, &GenServer.reply(&1, {:shared, result}))
        {:noreply, probes}
    end
  end

  def handle_cast({:abandoned, server}, probes), do: {:noreply, hand_over(probes, server)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, probes) do
    case Enum.find(probes, fn {_server, probe} -> probe.monitor == monitor end) do
      {server, _probe} -> {:noreply, hand_over(probes, server)}
      nil -> {:noreply, probes}
    end
  end

  # Lets the next waiting process probe, if there is one.
  defp hand_over(probes, server) do
    case Map.pop(probes, server) do
      {nil, probes} ->
        probes

      {probe, probes} ->
        Process.demonitor(probe.monitor, [:flush])

        case probe.waiting do
          [] ->
            probes

          [{pid, _tag} = next | waiting] ->
            GenServer.reply(next, :probe)
            Map.put(probes, server, %{monitor: Process.monitor(pid), waiting: waiting})
        end
    end
  end
end
