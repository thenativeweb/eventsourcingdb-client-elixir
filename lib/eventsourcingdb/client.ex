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

    - `:stall_timeout` - How many milliseconds a request waits for the server without anything arriving before it fails, while connecting, while waiting for the response headers, or while waiting for the rest of the response. Without it, the `receive_timeout` of the `req_options`, if there is one, or else 30 seconds

    """
    field :api_token, String.t(), enforce: true
    field :base_url, String.t() | URI.t(), enforce: true
    field :req_options, keyword(), default: []
    field :stall_timeout, pos_integer() | :infinity | nil
  end

  def new(base_url, api_token), do: new(base_url: base_url, api_token: api_token)

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:api_token, :base_url, :req_options, :stall_timeout])
      |> Keyword.update(:base_url, URI.new!(""), &URI.parse/1)

    client = struct!(__MODULE__, options)

    if Keyword.has_key?(options, :stall_timeout) do
      validate_stall_timeout!(client.stall_timeout)
    end

    %{client | stall_timeout: stall_timeout(client)}
  end

  # A client that sets no stall timeout, but passes a receive timeout on to
  # Req, waits for the receive timeout instead, as it always has for the
  # requests that the receive timeout bounded, so that no request ends earlier
  # than before.
  @doc false
  @spec stall_timeout(t()) :: pos_integer() | :infinity
  def stall_timeout(%__MODULE__{stall_timeout: nil, req_options: req_options}) do
    Keyword.get(req_options || [], :receive_timeout, @default_stall_timeout)
  end

  def stall_timeout(%__MODULE__{stall_timeout: stall_timeout}), do: stall_timeout

  defp validate_stall_timeout!(stall_timeout)
       when is_integer(stall_timeout) and stall_timeout > 0,
       do: :ok

  defp validate_stall_timeout!(stall_timeout) do
    raise ArgumentError,
          "expected :stall_timeout to be a positive integer of milliseconds, got: #{inspect(stall_timeout)}"
  end
end
