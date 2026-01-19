defmodule EventSourcingDB.Client do
  @type t() :: %__MODULE__{
          api_token: String.t(),
          base_url: String.t()
        }

  @enforce_keys [:api_token, :base_url]
  defstruct [:api_token, :base_url]

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    options =
      options
      |> Keyword.validate!([:api_token, :base_url])
      |> Keyword.update(:base_url, URI.new!(""), &URI.parse/1)

    struct!(__MODULE__, options)
  end
end
