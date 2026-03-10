defmodule EventSourcingDB.Requests.RunEventQL do
  @moduledoc false
  alias EventSourcingDB.Requests.RunEventQL
  alias EventSourcingDB.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/run-eventql-query"
  type "row"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  typedstruct do
    field :query, String.t(), enforce: true
  end

  @spec new(String.t()) :: RunEventQL.t()
  def new(query) do
    struct!(__MODULE__, query: query)
  end

  # region response
  # validation and parsing
end
