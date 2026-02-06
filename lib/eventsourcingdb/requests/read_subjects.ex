defmodule Eventsourcingdb.Requests.ReadSubjects do
  alias Eventsourcingdb.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  method :post
  path "/api/v1/read-subjects"
  type "subject"

  typedstruct do
    field :base_subject, String.t(), enforce: true
  end

  @spec new(String.t()) :: struct()
  def new(base_subject) do
    struct!(__MODULE__, base_subject: base_subject)
  end

  def process(data), do: data["subject"]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"baseSubject" => value.base_subject}, opts)
    end
  end
end
