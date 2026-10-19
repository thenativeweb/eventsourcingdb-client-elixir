defmodule EventSourcingDB.TestContainer do
  @moduledoc """
  Using Testcontainers for Testing

  Follow the instructions to [setup test containers for elixir](https://github.com/testcontainers/testcontainers-elixir).

  Then you are ready to use the provided `TestContainer` in your tests:

  ```elixir
  defmodule YourTest do
    alias EventSourcingDB.TestContainer
    use ExUnit.Case

    setup do
      {:ok, esdb} = TestContainer.start(TestContainer.new())
      on_exit(fn -> TestContainer.stop(esdb) end)

      %{esdb: esdb}
    end

    test "ping", %{esdb: esdb} do
      client = TestContainer.get_client(esdb)

      assert EventSourcingDB.ping(client) == :ok
    end
  end
  ```

  ### Configuring the Container Instance

  By default, `TestContainer` uses the `latest` tag of the official EventSourcingDB Docker image. To change that, call the `with_image_tag` function:

  ```elixir
  TestContainer.new()
  |> TestContainer.with_image_tag("1.0.0")
  ```

  Similarly, you can configure the port to use and the API token. Call the `with_port` or the `with_api_token` function respectively:

  ```elixir
  TestContainer.new()
  |> TestContainer.with_port(4000)
  |> TestContainer.with_api_token("secret")
  ```

  If you want to sign events, call the `with_signing_key` function. This generates a new signing and verification key pair inside the container:

  ```elixir
  TestContainer.new()
  |> TestContainer.with_signing_key()
  ```

  You can retrieve the private key (for signing) and the public key (for verifying signatures) once the container has been started:

  ```elixir
  signing_key = TestContainer.get_signing_key(esdb)
  verification_key = TestContainer.get_verification_key(esdb)
  ```

  The `signing_key` is the private key EventSourcingDB signs events with. The `verification_key` can be passed to `Event.verify_signature` when verifying events read from the database.

  The `start` function pulls the image if it is missing, and then waits until the database in the container answers a ping, for 30 seconds at most, not counting the pull. To change this time, call the `with_startup_timeout` function with the milliseconds:

  ```elixir
  TestContainer.new()
  |> TestContainer.with_startup_timeout(60_000)
  ```

  If a container keeps running, but does not become reachable in time, `start` replaces it with a new one, up to three containers in total, and then returns an `EventSourcingDB.Errors.ContainerStartFailed`. If Docker fails, or if the container exits, `start` returns that error at once, which, if the container exited, contains the last 20 lines of its log. In any case, `start` removes every container that it failed to start.

  ### Configuring the Client Manually

  In case you need to set up the client yourself, use the following functions to get details on the container:

  - `TestContainer.get_base_url(esdb)` returns the full URL of the container
  - `TestContainer.get_mapped_port(esdb)` returns the mapped port
  - `TestContainer.get_api_token(esdb)` returns the API token

  """

  alias EventSourcingDB.Client
  alias EventSourcingDB.Errors.ContainerStartFailed
  alias EventSourcingDB.TestContainer.Start
  alias Testcontainers.ContainerBuilder
  alias Testcontainers.Container

  @default_image_tag "latest"
  @default_port 3000
  @default_api_token "secret"
  @default_startup_timeout 30_000

  defstruct image_tag: @default_image_tag,
            api_token: @default_api_token,
            port: @default_port,
            signing_key: nil,
            startup_timeout: @default_startup_timeout

  @type t() :: %__MODULE__{
          image_tag: String.t(),
          api_token: String.t(),
          port: pos_integer(),
          signing_key: {binary(), binary()} | nil,
          startup_timeout: pos_integer()
        }

  @doc """
  Creates a new Testcontainer with default settings - ready for immediate use
  """
  def new,
    do: %__MODULE__{
      image_tag: @default_image_tag,
      port: @default_port,
      api_token: @default_api_token,
      startup_timeout: @default_startup_timeout
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

  @doc """
  Enables event signing for the testcontainer by generating an Ed25519 key pair.

  The signing key is used by the server to sign events. The corresponding
  verification key can be retrieved via `get_verification_key/1` after the
  container has started.
  """
  def with_signing_key(%__MODULE__{} = config) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    %{config | signing_key: {public_key, private_key}}
  end

  @doc """
  Sets how many milliseconds `start/1` waits for the database in a container
  to become reachable, from when Docker created the container until the
  database answers a ping. The default is 30 seconds. Pulling the image does
  not count.

  ```elixir
  TestContainer.new()
  |> TestContainer.with_startup_timeout(60_000)
  ```
  """
  def with_startup_timeout(%__MODULE__{} = config, startup_timeout)
      when is_integer(startup_timeout) and startup_timeout > 0 do
    %{config | startup_timeout: startup_timeout}
  end

  @doc """
  Starts a container with the database, and waits until the database answers
  a ping with the status `200`, for the startup timeout at most.

  If the container runs, but the database does not become reachable in time,
  for example because Docker did not publish its port, `start` replaces the
  container with a new one, up to 3 containers in total. If Docker fails, or
  if the container exits, `start` returns an error at once, which names the
  last 20 lines of the log of the container in the latter case. Whenever a
  container fails to start, `start` removes it.

  Returns `{:ok, container}`, or `{:error, %EventSourcingDB.Errors.ContainerStartFailed{}}`.

  Starting the container with `Testcontainers.start_container/1` instead, as
  the `container` macro of `Testcontainers.ExUnit` does, waits for the
  database as before, without the startup timeout, and without replacing the
  container.
  """
  @spec start(t()) :: {:ok, Container.t()} | {:error, ContainerStartFailed.t()}
  def start(%__MODULE__{} = config), do: Start.run(config)

  @doc """
  Stops and removes a container that `start/1` started.
  """
  @spec stop(Container.t()) :: :ok | {:error, term()}
  def stop(%Container{} = container), do: Testcontainers.stop_container(container.container_id)

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

  @doc """
  Returns the Ed25519 private key the server signs events with.

  Only available when the container was created with `with_signing_key/1`.
  """
  def get_signing_key(%Container{} = container) do
    case container.environment[:ESDB_SIGNING_KEY] do
      nil -> raise ArgumentError, "the container was started without a signing key"
      signing_key -> Base.decode16!(signing_key, case: :lower)
    end
  end

  @doc """
  Returns the Ed25519 public key for verifying event signatures.

  This key can be passed to `EventSourcingDB.Event.verify_signature/2`.
  Only available when the container was created with `with_signing_key/1`.
  """
  def get_verification_key(%Container{} = container) do
    container.environment[:ESDB_VERIFICATION_KEY]
    |> Base.decode16!(case: :lower)
  end

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
    alias Testcontainers.HttpWaitStrategy

    import Container

    @image_name "thenativeweb/eventsourcingdb"

    # When Testcontainers starts the container itself, as the container macro
    # of Testcontainers.ExUnit does, the container is ready once
    # EventSourcingDB answers its ping, and a container that answers within
    # 10 seconds is always found ready. TestContainer.start/1 leaves this wait
    # out, and waits on its own instead.
    #
    # HttpWaitStrategy pauses between its attempts for 0.5 seconds at first,
    # doubling up to 5 seconds, so after the 10 seconds, another attempt
    # follows within 5 seconds. So the wait ends after 16 seconds at the
    # latest, which leaves that attempt a second. HttpWaitStrategy bounds all
    # its attempts together, with the pauses between them, by its timeout
    # divided by its number of retries, so its timeout is the 16 seconds
    # times the retries. The retries last for longer than the 16 seconds.
    @ready_within 10_000
    @longest_pause 5_000
    @last_attempt 1_000
    @wait_retries 20
    @wait_timeout @ready_within + @longest_pause + @last_attempt

    @impl true
    def build(config) do
      cmd = [
        "run",
        "--api-token",
        config.api_token,
        "--data-directory-temporary",
        "--http-enabled",
        "--https-enabled=false",
        "--http-port",
        Integer.to_string(config.port)
      ]

      container =
        new("#{@image_name}:#{config.image_tag}")
        |> with_exposed_port(config.port)
        |> with_environment(:ESDB_PORT, Integer.to_string(config.port))
        |> with_environment(:ESDB_API_TOKEN, config.api_token)
        |> with_waiting_strategy(
          HttpWaitStrategy.new("/api/v1/ping", config.port,
            timeout: @wait_timeout * @wait_retries,
            max_retries: @wait_retries,
            status_code: 200
          )
        )

      {container, cmd} =
        if config.signing_key do
          {public_key, private_key} = config.signing_key

          jwk =
            JOSE.JWK.from_map(%{
              "kty" => "OKP",
              "crv" => "Ed25519",
              "d" => Base.url_encode64(private_key, padding: false),
              "x" => Base.url_encode64(public_key, padding: false)
            })

          {_type, pem} = JOSE.JWK.to_pem(jwk)

          container =
            container
            |> with_copy_to("/tmp/signing-key.pem", pem)
            |> with_environment(
              :ESDB_VERIFICATION_KEY,
              Base.encode16(public_key, case: :lower)
            )
            # The signing key is in the container anyway, as the file the
            # server reads it from, so it adds nothing to expose it here, too.
            |> with_environment(
              :ESDB_SIGNING_KEY,
              Base.encode16(private_key, case: :lower)
            )

          cmd = cmd ++ ["--signing-key-file=/tmp/signing-key.pem"]

          {container, cmd}
        else
          {container, cmd}
        end

      container |> with_cmd(cmd)
    end

    @impl true
    def after_start(_config, _container, _conn), do: :ok
  end
end
