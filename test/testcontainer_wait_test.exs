defmodule EventSourcingDBTest.TestContainerWait do
  alias EventSourcingDB.TestContainer
  alias Testcontainers.{Container, ContainerBuilder, WaitStrategy}
  use ExUnit.Case, async: true

  # EventSourcingDB takes a while to start when Docker is busy, so the test
  # container waits up to 10 seconds for it to answer its ping. The test runs
  # the wait of the test container against a local server that begins to
  # listen only after a few seconds, as such a server does.
  @ready_after 2_500

  test "waits for EventSourcingDB to answer its ping for longer than a second" do
    port = free_port()
    start_supervised!({Task, fn -> listen_later(port, @ready_after) end})

    %Container{wait_strategies: [wait_strategy]} = ContainerBuilder.build(TestContainer.new())
    container = %Container{image: "thenativeweb/eventsourcingdb", exposed_ports: [{3000, port}]}

    assert WaitStrategy.wait_until_container_is_ready(wait_strategy, container, nil) == :ok
  end

  defp free_port() do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Refuses every connection until it listens, and then answers every request
  # as EventSourcingDB answers its ping.
  defp listen_later(port, delay) do
    Process.sleep(delay)
    {:ok, listen_socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    answer(listen_socket)
  end

  defp answer(listen_socket) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, _request} = :gen_tcp.recv(socket, 0)
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
    :gen_tcp.close(socket)
    answer(listen_socket)
  end
end
