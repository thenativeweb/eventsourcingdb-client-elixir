defmodule EventSourcingDB.TestContainer.PingWaitStrategy do
  @moduledoc false

  # The wait with which Testcontainers starts the container of a
  # TestContainer itself, as the container macro of Testcontainers.ExUnit
  # does. TestContainer.start/1 leaves it out, and waits on its own instead.
  # Each attempt asks what TestContainer.Ping asks, which a wait strategy of
  # Testcontainers can not, as each of them asks a single path.
  #
  # The container is ready once EventSourcingDB answers its ping, and a
  # container that answers within 10 seconds is always found ready. The
  # attempts pause for 0.5 seconds at first, doubling up to 5 seconds, so
  # after the 10 seconds, another attempt follows within 5 seconds. So the
  # wait ends after 16 seconds, which leaves that attempt a second. Each
  # request may take whatever is left of the 16 seconds, so a request that
  # runs out of time ends the wait.

  alias EventSourcingDB.TestContainer.Ping
  alias Testcontainers.Container

  @ready_within 10_000
  @first_pause 500
  @longest_pause 5_000
  @last_attempt 1_000

  defstruct [:port, timeout: @ready_within + @longest_pause + @last_attempt]

  @type t() :: %__MODULE__{port: pos_integer(), timeout: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(port), do: %__MODULE__{port: port}

  @doc false
  @spec wait_until_ready(t(), Container.t()) :: :ok | {:error, :timeout, t()}
  def wait_until_ready(%__MODULE__{} = wait_strategy, %Container{} = container) do
    host = Testcontainers.get_host(container)
    port = Testcontainers.get_port(container, wait_strategy.port)
    deadline = now() + wait_strategy.timeout

    wait(wait_strategy, "http://#{host}:#{port}/", deadline, @first_pause)
  end

  defp wait(wait_strategy, base_url, deadline, pause) do
    if Ping.answers?(base_url, deadline, :infinity) do
      :ok
    else
      remaining = deadline - now()

      if remaining > 0 do
        Process.sleep(min(pause, remaining))
        wait(wait_strategy, base_url, deadline, min(2 * pause, @longest_pause))
      else
        {:error, :timeout, wait_strategy}
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defimpl Testcontainers.WaitStrategy do
    alias EventSourcingDB.TestContainer.PingWaitStrategy

    @impl true
    def wait_until_container_is_ready(wait_strategy, container, _conn),
      do: PingWaitStrategy.wait_until_ready(wait_strategy, container)
  end
end
