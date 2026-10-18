defmodule EventSourcingDB.Requests.WriteEvents do
  @moduledoc false
  alias EventSourcingDB.EventCandidate
  alias EventSourcingDB.Errors.TransmissionError
  alias EventSourcingDB.{OneShotRequest, Endpoint, Event, RawJSON}

  use Endpoint
  use OneShotRequest
  use TypedStruct

  # region metadata

  method :post
  path "/api/v1/write-events"

  # region request
  # parameters and serialization

  @derive Jason.Encoder
  typedstruct do
    field :events, EventCandidate.t()
    field :preconditions, any(), default: []
  end

  def new(events, preconditions \\ []) do
    struct!(__MODULE__, events: events, preconditions: preconditions)
  end

  # region response
  # validation and parsing

  # The body is decoded here rather than by Req, so that each event keeps the
  # text of its data as it arrived, for verifying its hash.
  def request_options(), do: [decode_body: false]

  def validate_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        raw_data = body |> RawJSON.elements() |> Enum.map(&RawJSON.member(&1, "data"))

        # Should the texts not match the events, the events verify their hash
        # as Jason encodes their data again, rather than any event get lost.
        raw_data =
          if length(raw_data) == length(payload),
            do: raw_data,
            else: List.duplicate(nil, length(payload))

        {:ok, Enum.zip_with(payload, raw_data, &Event.new/2)}

      {:error, reason} ->
        {:error, %TransmissionError{reason: reason}}
    end
  end

  def validate_body(payload) do
    {:ok, Enum.map(payload, &Event.new/1)}
  end
end
