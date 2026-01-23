defmodule Eventscourcingdb.Client do
  @typedoc """
  EventSourcingDB Client

  ## Options

  - `:base_url` - URL to your EventSourcingDB instance

  - `:api_token` - The API token to connect to your EventSourcingDB instance

  - `:retry` - See `:retry` options for `Req`

  """
  @type t() :: %__MODULE__{
          api_token: String.t(),
          base_url: String.t(),
          retry: any()
        }

  @enforce_keys [:api_token, :base_url]
  defstruct [:api_token, :base_url, :retry]

  def new(base_url, api_token), do: new(base_url: base_url, api_token: api_token)

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:api_token, :base_url, :retry])
      |> Keyword.update(:base_url, URI.new!(""), &URI.parse/1)

    struct!(__MODULE__, options)
  end
end
