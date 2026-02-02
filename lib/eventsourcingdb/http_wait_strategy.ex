# SPDX-License-Identifier: MIT
defmodule Eventsourcingdb.HttpWaitStrategy do
  @moduledoc """
  Considers the container as ready when it successfully accepts connections on the specified port.
  """

  require Logger

  @retry_delay 200
  @timeout 5000
  @status_code 200

  defstruct [
    :endpoint,
    status_code: @status_code,
    timeout: @timeout,
    retry_delay: @retry_delay
  ]

  # Public interface

  @doc """
  Creates a new PortWaitStrategy to wait until a specified port is open and accepting connections.
  """
  def new(endpoint, options \\ []) do
    struct(%__MODULE__{endpoint: endpoint}, options)
  end

  # Private functions and implementations

  defimpl Testcontainers.WaitStrategy do
    alias Eventsourcingdb.TestContainer

    @impl true
    def wait_until_container_is_ready(wait_strategy, container, _conn) do
      with base_url <- TestContainer.get_base_url(container),
           do: perform_port_check(wait_strategy, base_url)
    end

    defp perform_port_check(wait_strategy, base_url) do
      started_at = current_time_millis()

      case wait_for_endpoint_reached(wait_strategy, base_url, started_at) do
        :port_is_open ->
          :ok

        {:error, reason} ->
          {:error, reason, wait_strategy}
      end
    end

    defp wait_for_endpoint_reached(wait_strategy, base_url, start_time) do
      if reached_timeout?(wait_strategy.timeout, start_time) do
        {:error, strategy_timed_out(wait_strategy.timeout, start_time)}
      else
        check_endpoint_status(wait_strategy, base_url, start_time)
      end
    end

    defp check_endpoint_status(wait_strategy, base_url, start_time) do
      if endpoint_reached?(wait_strategy, base_url) do
        :port_is_open
      else
        log_retry_message(wait_strategy, base_url)
        :timer.sleep(wait_strategy.retry_delay)
        wait_for_endpoint_reached(wait_strategy, base_url, start_time)
      end
    end

    defp endpoint_reached?(wait_strategy, base_url) do
      status = wait_strategy.status_code

      case Req.get(base_url: base_url, url: wait_strategy.endpoint) do
        {:ok, %{status: ^status}} ->
          true

        _ ->
          false
      end
    end

    defp current_time_millis(), do: System.monotonic_time(:millisecond)

    defp reached_timeout?(timeout, start_time), do: current_time_millis() - start_time > timeout

    defp strategy_timed_out(timeout, start_time) do
      {:port_wait_strategy, :timeout, timeout, elapsed_time: current_time_millis() - start_time}
    end

    defp log_retry_message(wait_strategy, host_port) do
      Logger.debug(
        "Port #{wait_strategy.port} (host port #{host_port}) not open on IP #{wait_strategy.ip}, retrying in #{wait_strategy.retry_delay}ms."
      )
    end
  end
end
