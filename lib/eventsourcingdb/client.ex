defmodule EventSourcingDB.Client do
  @moduledoc """
  A `Client` holds the connection parameters to your EventSourcingDB instance

  ```elixir
  base_url = "localhost:3000"
  api_token = "secret"
  client = EventSourcingDB.Client.new(base_url, api_token)
  ```
  """
  use TypedStruct

  @default_stall_timeout 30_000

  typedstruct do
    @typedoc """
    EventSourcingDB Client

    ## Options

    - `:base_url` - URL to your EventSourcingDB instance

    - `:api_token` - The API token to connect to your EventSourcingDB instance

    - `:req_options` - Any additional options for [`Req`](https://hexdocs.pm/req)

    - `:stall_timeout` - How many milliseconds a request waits while nothing at all arrives from the server before it fails, 30 seconds by default

    """
    field :api_token, String.t(), enforce: true
    field :base_url, String.t() | URI.t(), enforce: true
    field :req_options, keyword(), default: []
    field :stall_timeout, pos_integer(), default: @default_stall_timeout
  end

  def new(base_url, api_token), do: new(base_url: base_url, api_token: api_token)

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:api_token, :base_url, :req_options, :stall_timeout])
      |> Keyword.update(:base_url, URI.new!(""), &URI.parse/1)

    validate_stall_timeout!(Keyword.get(options, :stall_timeout, @default_stall_timeout))

    struct!(__MODULE__, options)
  end

  defp validate_stall_timeout!(stall_timeout)
       when is_integer(stall_timeout) and stall_timeout > 0,
       do: :ok

  defp validate_stall_timeout!(stall_timeout) do
    raise ArgumentError,
          "expected :stall_timeout to be a positive integer of milliseconds, got: #{inspect(stall_timeout)}"
  end
end
