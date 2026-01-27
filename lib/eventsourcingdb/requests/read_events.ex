defmodule Eventsourcingdb.Requests.ReadEvents do
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/read-events"
  type "event"

  typedstruct do
    field :subject, String.t(), enforce: true
  end

  @spec new(String.t()) :: struct()
  def new(subject) do
    struct!(__MODULE__, subject: subject)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(
        %{"subject" => value.subject, "options" => %{"recursive" => true}},
        opts
      )
    end
  end
end
