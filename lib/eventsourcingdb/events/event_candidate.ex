defmodule Eventsourcingdb.Events.EventCandidate do
  @type t() :: %__MODULE__{
          data: map(),
          source: String.t(),
          subject: String.t(),
          type: String.t()
        }

  defstruct [
    :data,
    :source,
    :subject,
    :type
  ]

  defimpl Jason.Encoder do
    def encode(value, opts) do
      Jason.Encode.map(Map.from_struct(value), opts)
    end
  end
end
