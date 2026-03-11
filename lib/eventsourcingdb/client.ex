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

  typedstruct do
    @typedoc """
    EventSourcingDB Client

    ## Options

    - `:base_url` - URL to your EventSourcingDB instance

    - `:api_token` - The API token to connect to your EventSourcingDB instance

    - `:req_options` - Any additional options for [`Req`](https://hexdocs.pm/req)

    """
    field :api_token, String.t(), enforce: true
    field :base_url, String.t() | URI.t(), enforce: true
    field :req_options, keyword(), default: []
  end

  def new(base_url, api_token), do: new(base_url: base_url, api_token: api_token)

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:api_token, :base_url, :req_options])
      |> Keyword.update(:base_url, URI.new!(""), &URI.parse/1)

    struct!(__MODULE__, options)
  end
end
