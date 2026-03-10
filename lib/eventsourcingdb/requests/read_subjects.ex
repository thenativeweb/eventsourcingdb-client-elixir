defmodule EventSourcingDB.Requests.ReadSubjects do
  @moduledoc false
  alias EventSourcingDB.Requests.ReadSubjects
  alias EventSourcingDB.{StreamRequest, Endpoint}

  use Endpoint
  use StreamRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/read-subjects"
  type "subject"

  # region request
  # parameters and serialization

  typedstruct do
    field :base_subject, String.t(), enforce: true
  end

  @spec new(String.t()) :: ReadSubjects.t()
  def new(base_subject) do
    struct!(__MODULE__, base_subject: base_subject)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(%{"baseSubject" => value.base_subject}, opts)
    end
  end

  # region response
  # validation and parsing

  def process(data), do: data["subject"]
end
