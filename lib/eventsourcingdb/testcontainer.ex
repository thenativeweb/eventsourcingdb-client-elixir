defmodule Eventsourcingdb.TestContainer do
  alias Eventsourcingdb.Client
  alias Testcontainers.ContainerBuilder
  alias Testcontainers.Container

  @default_image_tag "latest"
  @default_port 3000
  @default_api_token "secret"

  defstruct image_tag: @default_image_tag,
            api_token: @default_api_token,
            port: @default_port

  # :port,
  # reuse: false
  def new,
    do: %__MODULE__{
      image_tag: @default_image_tag,
      port: @default_port,
      api_token: @default_api_token
    }

  def with_image_tag(%__MODULE__{} = config, image_tag) when is_binary(image_tag) do
    %{config | image_tag: image_tag}
  end

  def with_port(%__MODULE__{} = config, port) when is_integer(port) do
    %{config | port: port}
  end

  def with_api_token(%__MODULE__{} = config, api_token) do
    %{config | api_token: api_token}
  end

  @doc """
  Returns the port on the _host machine_ where the EventSourcingDB container is listening.
  """
  def get_mapped_port(%Container{} = container),
    do: Container.mapped_port(container, @default_port)

  @doc """
  Generates the base_url for accessing the EventSourcingDB service running within the container.

  This URL is based on the standard localhost IP and the mapped port for the container.

  ## Parameters

  - `container`: The active EventSourcingDB container instance in the form of a %Container{} struct.

  ## Examples

      iex> TestContainer.get_base_url(container)
      "http://localhost:32768" # This value will be different depending on the mapped port.
  """
  def get_base_url(%Container{} = container),
    do: "http://#{Testcontainers.get_host()}:#{get_mapped_port(container)}/"

  def get_api_token(%Container{} = container), do: container.environment[:ESDB_API_TOKEN]

  def get_client(%Container{} = container) do
    IO.inspect(get_base_url(container), label: "Client base url")

    Client.new(
      base_url: get_base_url(container),
      api_token: get_api_token(container)
    )
  end

  defimpl ContainerBuilder do
    alias Eventsourcingdb.Client

    import Container

    @image_name "thenativeweb/eventsourcingdb"

    @impl true
    def build(builder) do
      new("#{@image_name}:#{builder.image_tag}")
      |> with_exposed_port(builder.port)
      |> with_environment(:ESDB_API_TOKEN, builder.api_token)
      |> with_cmd([
        "run",
        "--api-token",
        builder.api_token,
        "--data-directory-temporary",
        "--http-enabled",
        "--https-enabled=false"
      ])
    end

    @impl true
    def after_start(_config, _container, _conn), do: :ok
  end
end
