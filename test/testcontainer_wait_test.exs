defmodule EventSourcingDBTest.TestContainerWait do
  alias EventSourcingDB.TestContainer
  alias Testcontainers.{Container, ContainerBuilder, WaitStrategy}
  use ExUnit.Case, async: true

  import EventSourcingDBTest.Utils

  # Testcontainers waits for the database itself when it starts the
  # container, as the container macro of Testcontainers.ExUnit does, whether
  # the server offers the v2 API or not.
  @tag timeout: container_test_timeout()
  test "starts the container through Testcontainers once the database answers its ping" do
    {:ok, esdb} = Testcontainers.start_container(test_container())
    on_exit(fn -> Testcontainers.stop_container(esdb.container_id) end)

    assert EventSourcingDB.ping(TestContainer.get_client(esdb)) == :ok
  end

  # EventSourcingDB takes a while to start when Docker is busy, so the test
  # container finds it ready whenever it answers its ping within 10 seconds.
  # The test runs the wait of the test container against a local server that
  # begins to listen only after some seconds, as such a server does.
  for ready_after <- [2_500, 9_000] do
    @ready_after ready_after

    test "finds EventSourcingDB ready that answers its ping after #{ready_after} milliseconds" do
      port = free_port()
      start_supervised!({Task, fn -> listen_later(port, @ready_after) end})

      %Container{wait_strategies: [wait_strategy]} = ContainerBuilder.build(TestContainer.new())

      container = %Container{
        image: "thenativeweb/eventsourcingdb",
        exposed_ports: [{3000, port}]
      }

      assert WaitStrategy.wait_until_container_is_ready(wait_strategy, container, nil) == :ok
    end
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
