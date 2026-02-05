defmodule Eventsourcingdb.Requests.RunEventQL do
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/run-eventql-query"
  type "row"

  @derive Jason.Encoder
  typedstruct do
    field :query, String.t(), enforce: true
  end

  @spec new(String.t()) :: Eventsourcingdb.Requests.RunEventQL.t()
  def new(query) do
    struct!(__MODULE__, query: query)
  end
end
