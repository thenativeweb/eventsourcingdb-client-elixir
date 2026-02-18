defmodule EventSourcingDB.TestContainer do
  @moduledoc """
  Using Testcontainers for Testing

  Follow the instructions to [setup test containers for elixir](https://github.com/testcontainers/testcontainers-elixir).

  Then you are ready to use the provideded `TestContainer` in your tests:

  ```elixir
  defmodule YourTest do
    alias EventSourcingDB.TestContainer
    use ExUnit.Case

    import Testcontainers.ExUnit

    container(:esdb, TestContainer.new(())

    test "ping", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)

      # do sth with client

      assert EventSourcingDB.ping(client) == :ok
    end
  end
  ```

  ### Configuring the Container Instance

  By default, `TestContainer` uses the `latest` tag of the official EventSourcingDB Docker image. To change that use the provided builder and call the `with_image_tag` function.

  ```elixir
  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_image_tag("1.0.0")
  )
  ```

  Similarly, you can configure the port to use and the API token. Call the `with_port` or the `with_api_token` function respectively:

  ```elixir
  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_port(4000)
    |> TestContainer.with_api_token("secret")
  )
  ```

  """

  alias EventSourcingDB.Client
  alias Testcontainers.ContainerBuilder
  alias Testcontainers.Container

  @default_image_tag "latest"
  @default_port 3000
  @default_api_token "secret"

  defstruct image_tag: @default_image_tag,
            api_token: @default_api_token,
            port: @default_port,
            signing_key: nil

  # :port,
  # reuse: false
  @doc """
  Creates a new Testcontainer with default settings - ready for immediate use
  """
  def new,
    do: %__MODULE__{
      image_tag: @default_image_tag,
      port: @default_port,
      api_token: @default_api_token
    }

  @doc """
  Use a custom image tag or the testcontainer

  ```elixir
  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_image_tag("1.0.0")
  )
  ```
  """
  def with_image_tag(%__MODULE__{} = config, image_tag) when is_binary(image_tag) do
    %{config | image_tag: image_tag}
  end

  @doc """
  Use a custom port for the testcontainer

  ```elixir
  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_port(4000)
  )
  ```
  """
  def with_port(%__MODULE__{} = config, port) when is_integer(port) do
    %{config | port: port}
  end

  @doc """
  Use a custom api token for the testcontainer

  ```elixir
  container(
    :esdb,
    TestContainer.new()
    |> TestContainer.with_api_token("secret")
  )
  ```
  """
  def with_api_token(%__MODULE__{} = config, api_token) do
    %{config | api_token: api_token}
  end

  def with_signing_key(%__MODULE__{} = config) do
    signing_key = JOSE.JWK.generate_key({:okp, :Ed25519})

    %{config | signing_key: signing_key}
  end

  @doc """
  Returns the port on the _host machine_ where the EventSourcingDB container is listening.
  """
  def get_mapped_port(%Container{} = container),
    do: Container.mapped_port(container, String.to_integer(container.environment[:ESDB_PORT]))

  @doc """
  Generates the `base_url` for accessing the EventSourcingDB service running within the container.

  This URL is based on the standard localhost IP and the mapped port for the container.

  ## Parameters

  - `container`: The active EventSourcingDB container instance in the form of a `TestContainer` struct.

  ## Examples

      iex> TestContainer.get_base_url(container)
      "http://localhost:32768" # This value will be different depending on the mapped port.
  """
  def get_base_url(%Container{} = container),
    do: "http://#{Testcontainers.get_host()}:#{get_mapped_port(container)}/"

  @doc """
  Gets the API token for the given container

  ## Parameters

  - `container`: The active EventSourcingDB container instance in the form of a `TestContainer` struct.

  ## Examples

      iex> TestContainer.get_api_token(container)
      "secret"
  """
  def get_api_token(%Container{} = container), do: container.environment[:ESDB_API_TOKEN]

  def get_signing_key(%Container{} = container),
    do: Base.url_decode64!(container.environment[:ESDB_SIGNING_KEY], padding: false)

  @doc """
  Gets the EventSourcingDB client for the given container

  ## Parameters

  - `container`: The active EventSourcingDB container instance in the form of a `TestContainer` struct.

  ## Examples

      iex> TestContainer.get_client(container)
      %EventSourcingDB.Client{...}
  """
  def get_client(%Container{} = container) do
    Client.new(
      base_url: get_base_url(container),
      api_token: get_api_token(container)
    )
  end

  defimpl ContainerBuilder do
    alias Testcontainers.Docker
    alias Testcontainers.HttpWaitStrategy
    alias Eventsourcingdb.Client

    import Container

    @image_name "thenativeweb/eventsourcingdb"

    @impl true
    def build(config) do
      IO.inspect(config, label: "build, config")

      cmd = [
        "run",
        "--api-token",
        config.api_token,
        "--data-directory-temporary",
        "--http-enabled",
        "--https-enabled=false"
      ]

      container =
        new("#{@image_name}:#{config.image_tag}")
        |> with_exposed_port(config.port)
        |> with_environment(:ESDB_PORT, Integer.to_string(config.port))
        |> with_environment(:ESDB_API_TOKEN, config.api_token)
        |> with_waiting_strategy(
          HttpWaitStrategy.new("/api/v1/ping", config.port,
            timeout: 10_000,
            status_code: 200
          )
        )

      container =
        if config.signing_key do
          {_module, key_map} = JOSE.JWK.to_map(config.signing_key)

          container
          |> with_environment(
            :ESDB_SIGNING_KEY,
            Jason.encode!(key_map)
          )
        else
          container
        end

      cmd =
        if config.signing_key do
          cmd ++
            [
              "--signing-key-file=/etc/esdb/signing_key.pem"
            ]
        else
          cmd
        end

      IO.inspect(cmd, label: "cmd")

      container |> with_cmd(cmd)
    end

    @impl true
    def after_start(config, container, conn) do
      # see: https://github.com/testcontainers/testcontainers-elixir/issues/240
      if config.signing_key do
        {_, pem} = JOSE.JWK.to_pem(config.signing_key)

        Docker.Api.put_file(container.container_id, conn, "/etc/esdb/", "signing-key.pem", pem)
      end

      :ok
    end
  end
end
