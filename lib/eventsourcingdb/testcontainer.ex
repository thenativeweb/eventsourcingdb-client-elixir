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

  # @TODO implement this method
  def with_signing_key(%__MODULE__{} = config) do
    # reference implementation:
    # Javascript:
    # https://github.com/thenativeweb/eventsourcingdb-client-javascript/blob/9c7dbb79e90b6a8a55af2f3dcaf1398b783a4a4b/src/Container.ts#L30-L34
    # Rust:
    # https://github.com/thenativeweb/eventsourcingdb-client-rust/blob/efa6d1190a61104b50df0131b05f866fded4e15e/src/container.rs#L117-L121

    # Failing attempts:

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{config | signing_key: {public_key, private_key}}

    # signing_key = JOSE.JWK.generate_key({:okp, :Ed25519})

    # %{config | signing_key: signing_key}
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

  # @TODO implement `get_signing_key()` and `get_verification_key()`
  # see failing attempts below (there might be good stuff in there)

  def get_signing_key(%Container{} = container),
    do: container.environment[:ESDB_SIGNING_KEY]

  def get_verification_key(%Container{} = container),
    do: container.environment[:ESDB_VERIFICATION_KEY]

  # Failure attempts:

  # def get_verification_key(%Container{} = container) do
  #   {_, public_key} = get_signing_key(container)

  #   public_key
  # end

  # def get_signing_key(%Container{} = container),
  #   do:
  #     container.environment[:ESDB_SIGNING_KEY]
  #     |> Jason.decode!()
  #     |> JOSE.JWK.from_map()

  # def get_verification_key(%Container{} = container) do
  #   {key_type, {_, key_data}} = get_key(container) |> JOSE.JWK.to_public() |> JOSE.JWK.to_key()

  #   IO.inspect(key_type, label: "key type")
  #   IO.inspect(key_data, label: "key data")
  #   # {:ed_pub_key, key_data, :ed25519}
  #   key_data
  #   # {_module, public} = get_key(container) |> JOSE.JWK.to_public()
  #   # public
  # end

  # def get_signing_key(%Container{} = container),
  #   do: Base.url_decode64!(container.environment[:ESDB_SIGNING_KEY], padding: false)

  # def get_signing_key(%Container{} = container) do
  #   IO.inspect(container.environment[:ESDB_SIGNING_KEY], label: "env signing key")

  #   %{public_key: public_key, private_key: private_key} =
  #     Jason.decode!(container.environment[:ESDB_SIGNING_KEY])

  #   private_key_decoded = Base.decode64(private_key)
  #   public_key_decoded = Base.decode64(public_key)

  #   {private_key_decoded, public_key_decoded}
  # end

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

      # @TODO parametrize the container when a signing_key is present
      container =
        if config.signing_key do
          # @TODO
          # use config.signing_key to store what's needed in `:ESDB_SIGNING_KEY`
          # of `with_environment`. Maybe also use `:ESDB_VERIFICATION_KEY`, if
          # this eases the use of map, etc.

          # Reference implementation:
          # Javascript:
          # https://github.com/thenativeweb/eventsourcingdb-client-javascript/blob/9c7dbb79e90b6a8a55af2f3dcaf1398b783a4a4b/src/Container.ts#L53-L62
          # Rust: https://github.com/thenativeweb/eventsourcingdb-client-rust/blob/efa6d1190a61104b50df0131b05f866fded4e15e/src/container.rs#L149-L158

          container
          |> with_environment(
            :ESDB_SIGNING_KEY,
            "signing_key"
          )

          #       |> with_copy_to("/etc/esdb/signing_key.pem", private_pem)
        else
          container
        end

      # @TODO this should be good to uncomment then
      # cmd =
      #   if config.signing_key do
      #     cmd ++
      #       [
      #         "--signing-key-file=/etc/esdb/signing_key.pem"
      #       ]
      #   else
      #     cmd
      #   end

      container |> with_cmd(cmd)

      # Failing attempts:

      #   container =
      #     if config.signing_key do
      #       # {_module, key_map} = JOSE.JWK.to_map(config.signing_key)
      #       # {_module, pem} = JOSE.JWK.to_pem(config.signing_key)

      #       {public_key, private_key} = config.signing_key

      #       jwk =
      #         JOSE.JWK.from_map(%{
      #           "kty" => "OKP",
      #           "crv" => "Ed25519",
      #           "d" => Base.url_encode64(private_key, padding: false),
      #           "x" => Base.url_encode64(public_key, padding: false)
      #         })

      #       {_, private_pem} = JOSE.JWK.to_pem(jwk)

      #       # private_key_asn1 =
      #       #   :public_key.der_encode(:PrivateKeyInfo, {:ed_priv_key, private_key, :ed25519})

      #       # erl_priv_key = {:ed_priv_key, private_key, :ed25519}
      #       # priv_entry = :public_key.pem_entry_encode(:PrivateKeyInfo, private_key_asn1)
      #       # priv_entry = :public_key.pem_entry_encode(:PrivateKeyInfo, private_key)
      #       # private_pem = :public_key.pem_encode([priv_entry])
      #       # private_pem = :public_key.pem_encode([{:PrivateKeyInfo, private_key}])

      #       private_key_encoded = Base.encode64(private_key)
      #       public_key_encoded = Base.encode64(public_key)

      #       # pem = """
      #       # -----BEGIN PRIVATE KEY-----
      #       # #{private_key_encoded}
      #       # -----END PRIVATE KEY-----
      #       # """

      #       # IO.inspect(pem, label: "pem")
      #       IO.inspect(private_pem, label: "priv_pem")

      #       IO.inspect(%{public_key: public_key_encoded, private_key: private_key_encoded},
      #         label: "keys"
      #       )

      #       IO.inspect(
      #         Jason.encode!(%{public_key: public_key_encoded, private_key: private_key_encoded}),
      #         label: "json keys"
      #       )

      #       IO.inspect(
      #         Jason.encode!(%{
      #           "public_key" => public_key_encoded,
      #           "private_key" => private_key_encoded
      #         }),
      #         label: "json keys map"
      #       )

      #       container
      #       |> with_copy_to("/etc/esdb/signing_key.pem", private_pem)
      #       |> with_environment(
      #         :ESDB_SIGNING_KEY,
      #         private_key_encoded
      #       )
      #       |> with_environment(
      #         :ESDB_VERIFICATION_KEY,
      #         private_key_encoded
      #       )
      #     else
      #       container
      #     end
    end

    defp to_pem(key) do
      :public_key.pem_entry_encode(:EdDSA25519PrivateKey, key)
    end

    @impl true
    def after_start(_config, _container, _conn), do: :ok
  end
end
