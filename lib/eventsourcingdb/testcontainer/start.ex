defmodule EventSourcingDB.TestContainer.Start do
  @moduledoc false

  # Starts the container of a TestContainer, and waits until the database in
  # it answers a ping with 200 OK, as TestContainer.Ping asks for it.
  #
  # Each attempt starts a container through Testcontainers, and gives it a
  # label with an id of the attempt, so that the containers of an attempt that
  # failed can be found and removed, even one that Testcontainers did not hand
  # out. The time of an attempt runs from when Docker created its container,
  # so that pulling the image does not count. If the container runs, but the
  # database does not become reachable in that time, the attempt removes the
  # container, and the next attempt replaces it, up to 3 containers in total.
  # If Docker fails, or if the container exits, the start fails at once.
  #
  # Testcontainers creates and starts a container in a process of its own,
  # which the attempt can not stop. So a guard starts the container, and waits
  # for the attempt to say whether it took care of the container. Should the
  # attempt give up before the container was handed out, or end, the guard
  # removes the container once Testcontainers is done with it.

  alias DockerEngineAPI.Api.Container, as: DockerContainer
  alias DockerEngineAPI.Model.{ContainerInspectResponse, ErrorResponse}
  alias EventSourcingDB.Errors.ContainerStartFailed
  alias EventSourcingDB.TestContainer
  alias EventSourcingDB.TestContainer.Ping
  alias Testcontainers.{Container, ContainerBuilder}

  require Logger

  @attempts 3
  @start_label "io.eventsourcingdb.container-start"
  @poll_interval 100
  @ping_timeout 1_000
  @log_tail_lines 20
  @removal_checks 50

  @typedoc """
  Lets tests change how a container is started, inspected, and removed. Each
  hook takes the argument, and the function that would be called with it
  otherwise.
  """
  @type hooks() :: [
          start_container: (Container.t(), (Container.t() -> term()) -> term()),
          inspect_container: (String.t(), (String.t() -> inspection()) -> inspection()),
          remove_containers: (String.t(), (String.t() -> removal()) -> removal())
        ]

  # The status of a container, and the port on the host that Docker published
  # for the port of the database, if it did.
  @type inspection() :: {:ok, {String.t() | nil, pos_integer() | nil}} | {:error, term()}

  # Whether removing the containers of an attempt worked.
  @type removal() :: :ok | {:error, term()}

  @spec run(TestContainer.t(), hooks()) ::
          {:ok, Container.t()} | {:error, ContainerStartFailed.t()}
  def run(%TestContainer{} = config, hooks \\ []) do
    {conn, _docker_host_url, _docker_host} = Testcontainers.Connection.get_connection()

    docker = %{
      conn: conn,
      start_container:
        Keyword.get(hooks, :start_container, fn container, start -> start.(container) end),
      inspect_container:
        Keyword.get(hooks, :inspect_container, fn id, inspect -> inspect.(id) end),
      remove_containers:
        Keyword.get(hooks, :remove_containers, fn attempt_id, remove -> remove.(attempt_id) end)
    }

    run(config, docker, @attempts, [])
  end

  # Replaces a container that does not become reachable, even if removing it
  # failed, as long as Docker works otherwise. The removals that failed are
  # named after the message of the error, each on its own line, or logged if
  # the start works in the end.
  defp run(config, docker, attempts_left, failed_removals) do
    {result, removal} = attempt(config, docker)

    failed_removals =
      case removal do
        :ok -> failed_removals
        {:error, reason} -> failed_removals ++ [reason]
      end

    case result do
      :unreachable when attempts_left > 1 ->
        run(config, docker, attempts_left - 1, failed_removals)

      :unreachable ->
        {:error, with_removals(unreachable_error(config), failed_removals)}

      {:error, error} ->
        {:error, with_removals(error, failed_removals)}

      {:ok, container} ->
        for reason <- failed_removals do
          Logger.warning(
            "failed to remove the container of an attempt that failed: #{describe(reason)}"
          )
        end

        {:ok, container}
    end
  end

  defp attempt(config, docker) do
    attempt_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    container_config =
      %{ContainerBuilder.build(config) | wait_strategies: []}
      |> Container.with_label(@start_label, attempt_id)

    # The guard hands out the container through an alias, which the attempt
    # deactivates once it is done, so that nothing that arrives late lands in
    # the mailbox of the caller.
    reply_to = Process.alias()
    attempt = self()
    guard = spawn(fn -> guard(attempt, reply_to, docker, container_config, attempt_id) end)
    guard_ref = Process.monitor(guard)

    # Once the attempt took care of the container, it tells the guard so, or
    # that it gave up on a container that is still being started.
    {verdict, result} =
      case await_start(docker, attempt_id, reply_to, guard_ref, config.startup_timeout, nil) do
        {:handed_out, container, deadline} ->
          outcome = await_reachable(config, docker, container, deadline)
          {:done, finish(outcome, docker, attempt_id, container)}

        {:failed, reason} ->
          {:done, finish({:docker_error, reason}, docker, attempt_id, nil)}

        {:pending, outcome} ->
          {:abandoned, finish(outcome, docker, attempt_id, nil)}
      end

    send(guard, {reply_to, verdict})
    Process.unalias(reply_to)
    Process.demonitor(guard_ref, [:flush])

    receive do
      {^reply_to, _late} -> :ok
    after
      0 -> :ok
    end

    result
  end

  # Waits until Testcontainers hands out the container. The clock of the
  # attempt starts once Docker created the container, which the label of the
  # attempt shows, or at the latest once Testcontainers hands it out.
  defp await_start(docker, attempt_id, reply_to, guard_ref, startup_timeout, deadline) do
    wait = if deadline, do: max(deadline - now(), 0), else: @poll_interval

    receive do
      {^reply_to, {:ok, container}} ->
        {:handed_out, container, deadline || now() + startup_timeout}

      {^reply_to, {:error, reason}} ->
        {:failed, reason}

      {:DOWN, ^guard_ref, :process, _guard, reason} ->
        {:pending, {:docker_error, reason}}
    after
      wait ->
        if deadline do
          {:pending, :unreachable}
        else
          case containers(docker, attempt_id) do
            {:ok, []} ->
              await_start(docker, attempt_id, reply_to, guard_ref, startup_timeout, nil)

            {:ok, _created} ->
              await_start(
                docker,
                attempt_id,
                reply_to,
                guard_ref,
                startup_timeout,
                now() + startup_timeout
              )

            {:error, reason} ->
              {:pending, {:docker_error, reason}}
          end
        end
    end
  end

  # Pings the database until it answers with 200 OK, until the time runs out,
  # until the container exits, or until Docker fails. The port that Docker
  # published is read anew for each ping, as Docker may publish it only a
  # while after it started the container.
  defp await_reachable(config, docker, container, deadline) do
    inspect = &inspect_container(docker.conn, &1, config.port)

    case docker.inspect_container.(container.container_id, inspect) do
      {:ok, {status, _host_port}} when status in ["exited", "dead"] ->
        {:exited, log_tail(docker, container.container_id)}

      {:ok, {"running", host_port}} when is_integer(host_port) ->
        reachable = %{container | exposed_ports: [{config.port, host_port}]}

        if Ping.answers?(TestContainer.get_base_url(reachable), deadline, @ping_timeout) do
          {:ok, reachable}
        else
          retry_reachable(config, docker, container, deadline)
        end

      {:ok, _not_yet} ->
        retry_reachable(config, docker, container, deadline)

      {:error, reason} ->
        {:docker_error, reason}
    end
  end

  defp retry_reachable(config, docker, container, deadline) do
    remaining = deadline - now()

    if remaining > 0 do
      Process.sleep(min(@poll_interval, remaining))
      await_reachable(config, docker, container, deadline)
    else
      :unreachable
    end
  end

  # Removes the containers of an attempt that failed, and turns the outcome
  # into the result of the attempt, along with whether the removal worked. A
  # container that Testcontainers handed out is stopped through
  # Testcontainers, so that Testcontainers forgets it, too.
  defp finish({:ok, container}, _docker, _attempt_id, _container), do: {{:ok, container}, :ok}

  defp finish(outcome, docker, attempt_id, container) do
    if container do
      # The removal by the label below tells whether this worked.
      Testcontainers.stop_container(container.container_id)
    end

    removal = remove(docker, attempt_id)

    case outcome do
      :unreachable -> {:unreachable, removal}
      outcome -> {{:error, error(outcome)}, removal}
    end
  end

  defp unreachable_error(config) do
    %ContainerStartFailed{
      message:
        "failed to start the container, the database did not become reachable within " <>
          "#{seconds(config.startup_timeout)}s in any of #{@attempts} containers"
    }
  end

  defp error({:exited, {:ok, log_tail}}) do
    %ContainerStartFailed{
      message:
        "failed to start the container, it exited before the database became reachable: #{log_tail}"
    }
  end

  defp error({:exited, {:error, reason}}) do
    %ContainerStartFailed{
      message:
        "failed to start the container, it exited before the database became reachable, " <>
          "and failed to read its log: #{describe(reason)}",
      cause: reason
    }
  end

  defp error({:docker_error, reason}), do: docker_error(reason)

  defp docker_error(reason) do
    %ContainerStartFailed{
      message: "failed to start the container: #{describe(reason)}",
      cause: reason
    }
  end

  defp with_removals(%ContainerStartFailed{} = error, failed_removals) do
    removals =
      Enum.map_join(failed_removals, &"\nfailed to remove the container: #{describe(&1)}")

    %{error | message: error.message <> removals}
  end

  # Starts the container, hands it out to the attempt, and waits for the
  # attempt to say whether it took care of it. Should the attempt have given
  # up on the container, or have ended, the guard removes the container.
  defp guard(attempt, reply_to, docker, container_config, attempt_id) do
    attempt_ref = Process.monitor(attempt)
    started = start_container(docker, container_config)
    send(reply_to, {reply_to, started})

    receive do
      {^reply_to, :done} ->
        :ok

      {^reply_to, :abandoned} ->
        remove_abandoned(docker, started, attempt_id)

      {:DOWN, ^attempt_ref, :process, _attempt, _reason} ->
        remove_abandoned(docker, started, attempt_id)
    end
  end

  defp start_container(docker, container_config) do
    case docker.start_container.(container_config, &Testcontainers.start_container/1) do
      {:ok, %Container{} = container} -> {:ok, container}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp remove_abandoned(docker, started, attempt_id) do
    with {:ok, %Container{container_id: container_id}} <- started do
      # The removal by the label below tells whether this worked.
      Testcontainers.stop_container(container_id)
    end

    with {:error, reason} <- remove(docker, attempt_id) do
      Logger.warning(
        "failed to remove the container of a start that was given up: #{describe(reason)}"
      )
    end
  end

  defp remove(docker, attempt_id) do
    docker.remove_containers.(attempt_id, &remove_containers(docker, &1))
  end

  # Removes the containers with the label of the attempt, and checks that
  # none is left, for a while, as Docker may still be removing one.
  defp remove_containers(docker, attempt_id, checks \\ @removal_checks, last_error \\ nil) do
    case containers(docker, attempt_id) do
      {:ok, []} ->
        :ok

      {:ok, container_ids} when checks > 0 ->
        errors =
          for container_id <- container_ids,
              {:error, reason} <- [delete_container(docker, container_id)],
              do: reason

        Process.sleep(@poll_interval)
        remove_containers(docker, attempt_id, checks - 1, List.first(errors, last_error))

      {:ok, container_ids} ->
        {:error, last_error || {:containers_left, container_ids}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp containers(docker, attempt_id) do
    filters = Jason.encode!(%{"label" => ["#{@start_label}=#{attempt_id}"]})

    case DockerContainer.container_list(docker.conn, all: true, filters: filters) do
      {:ok, containers} when is_list(containers) -> {:ok, Enum.map(containers, & &1."Id")}
      {:ok, error} -> {:error, error}
      {:error, %Tesla.Env{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp delete_container(docker, container_id) do
    case DockerContainer.container_delete(docker.conn, container_id, force: true, v: true) do
      {:ok, %Tesla.Env{}} -> :ok
      {:ok, error} -> {:error, error}
      {:error, %Tesla.Env{status: status}} -> {:error, {:http_error, status}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp inspect_container(conn, container_id, port) do
    case DockerContainer.container_inspect(conn, container_id) do
      {:ok, %ContainerInspectResponse{State: state, NetworkSettings: network_settings}} ->
        {:ok, {status(state), host_port(network_settings, port)}}

      {:ok, error} ->
        {:error, error}

      {:error, %Tesla.Env{status: status}} ->
        {:error, {:http_error, status}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp status(%{Status: status}), do: status
  defp status(_state), do: nil

  defp host_port(%{Ports: %{} = ports}, port) do
    ports
    |> Map.get("#{port}/tcp")
    |> List.wrap()
    |> Enum.find_value(fn
      %{"HostPort" => host_port} when is_binary(host_port) ->
        case Integer.parse(host_port) do
          {host_port, ""} -> host_port
          _not_a_port -> nil
        end

      _binding ->
        nil
    end)
  end

  defp host_port(_network_settings, _port), do: nil

  defp log_tail(docker, container_id) do
    case Testcontainers.Docker.Api.stdout_logs(container_id, docker.conn) do
      {:ok, log} when is_binary(log) -> {:ok, tail(log)}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  end

  # The last lines of a log as Docker sends it for a container without a
  # terminal, in frames of what the container wrote to its standard output
  # and to its standard error, each with a header of 8 bytes. Blank lines at
  # the end of the log do not count.
  @doc false
  @spec tail(binary()) :: String.t()
  def tail(log) do
    log
    |> demultiplex([])
    |> String.replace(~r/[\r\n]+\z/, "")
    |> String.split(~r/\r?\n/)
    |> Enum.take(-@log_tail_lines)
    |> Enum.join("\n")
  end

  defp demultiplex(
         <<stream, 0, 0, 0, size::32, payload::binary-size(size), rest::binary>>,
         frames
       )
       when stream in 0..2,
       do: demultiplex(rest, [frames, payload])

  defp demultiplex(rest, frames), do: IO.iodata_to_binary([frames, rest])

  defp describe(%ErrorResponse{message: message}) when is_binary(message), do: message
  defp describe({_operation, %ErrorResponse{} = error}), do: describe(error)
  defp describe(exception) when is_exception(exception), do: Exception.message(exception)
  defp describe(message) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason)

  # Writes milliseconds as seconds, as an integer if they are whole, and as
  # short as possible otherwise, e.g. 30 or 1.5.
  defp seconds(milliseconds) when rem(milliseconds, 1_000) == 0,
    do: Integer.to_string(div(milliseconds, 1_000))

  defp seconds(milliseconds), do: Float.to_string(milliseconds / 1_000)

  defp now, do: System.monotonic_time(:millisecond)
end
