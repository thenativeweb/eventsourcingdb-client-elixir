defmodule Eventsourcingdb.Event do
  @moduledoc """
  An Event coming from the server.
  """
  alias Eventsourcingdb.Event
  use TypedStruct

  typedstruct do
    field :data, any(), enforce: true
    field :datacontenttype, String.t(), enforce: true
    field :hash, String.t(), enforce: true
    field :id, String.t(), enforce: true
    field :predecessorhash, String.t(), enforce: true
    field :signature, String.t()
    field :source, String.t(), enforce: true
    field :specversion, String.t(), enforce: true
    field :subject, String.t(), enforce: true
    field :time, String.t(), enforce: true
    field :traceparent, String.t()
    field :tracestate, String.t()
    field :type, String.t(), enforce: true
  end

  @spec new(map()) :: Event.t()
  def new(value \\ %{}) do
    struct!(__MODULE__, value |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end))
  end

  # original JS version:
  # const metadata = `${this.specversion}|${this.id}|${this.predecessorhash}|${this.#timeFromServer}|${this.source}|${this.subject}|${this.type}|${this.datacontenttype}`;

  # 	const metadataHash = crypto.createHash('sha256').update(metadata).digest('hex');
  # 	const dataHash = crypto.createHash('sha256').update(JSON.stringify(this.data)).digest('hex');

  # 	const finalHash = crypto
  # 		.createHash('sha256')
  # 		.update(`${metadataHash}${dataHash}`)
  # 		.digest('hex');

  @spec verify_hash(Event.t()) :: any()
  def verify_hash(event) do
    IO.inspect(event, label: "event")
    IO.inspect(DateTime.from_iso8601(event.time), label: "time")

    metadata =
      "#{event.specversion}|#{event.id}|#{event.predecessorhash}|#{event.time}|#{event.source}|#{event.subject}|#{event.type}|#{event.datacontenttype}"

    IO.inspect(metadata, label: "metadata")

    metadata_hash = :crypto.hash(:sha256, metadata) |> Base.encode16()
    data_hash = :crypto.hash(:sha256, Jason.encode!(event.data)) |> Base.encode16()
    final_hash = :crypto.hash(:sha256, "#{metadata_hash}#{data_hash}") |> Base.encode16()

    case final_hash == event.hash do
      true -> :ok
      false -> {:error, :hash_verification_failed, [expected: event.hash, actual: final_hash]}
    end
  end
end
