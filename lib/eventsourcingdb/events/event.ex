defmodule EventSourcingDB.Event do
  @moduledoc """
  An Event coming from the server.
  """
  alias EventSourcingDB.Event

  alias EventSourcingDB.Errors.{
    HashVerificationFailed,
    MalformedSignature,
    SignatureMissing,
    SignatureVerificationFailed
  }

  use TypedStruct

  @signature_prefix "esdb:signature:v1:"

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

  @spec verify_hash(Event.t()) :: :ok | {:error, HashVerificationFailed.t()}
  def verify_hash(event) do
    metadata =
      "#{event.specversion}|#{event.id}|#{event.predecessorhash}|#{event.time}|#{event.source}|#{event.subject}|#{event.type}|#{event.datacontenttype}"

    metadata_hash = :crypto.hash(:sha256, metadata) |> Base.encode16(case: :lower)
    data_hash = :crypto.hash(:sha256, Jason.encode!(event.data)) |> Base.encode16(case: :lower)

    final_hash =
      :crypto.hash(:sha256, "#{metadata_hash}#{data_hash}") |> Base.encode16(case: :lower)

    if final_hash == event.hash do
      :ok
    else
      {:error, %HashVerificationFailed{expected: event.hash, actual: final_hash}}
    end
  end

  @spec verify_signature(Event.t(), any()) ::
          :ok
          | {:error, HashVerificationFailed.t()}
          | {:error, MalformedSignature.t()}
          | {:error, SignatureMissing.t()}
          | {:error, SignatureVerificationFailed.t()}
  def verify_signature(event, key) do
    with {:ok, signature} <- check_signature_presence(event),
         :ok <- Event.verify_hash(event),
         {:ok, signature} <- check_signature_format(signature) do
      signature_bytes = Base.decode16!(signature, case: :lower)
      hash_bytes = event.hash

      case :crypto.verify(:eddsa, :none, hash_bytes, signature_bytes, [key, :ed25519]) do
        true -> :ok
        false -> {:error, %SignatureVerificationFailed{}}
      end
    end
  end

  defp check_signature_presence(event) do
    if event.signature do
      {:ok, event.signature}
    else
      {:error, %SignatureMissing{}}
    end
  end

  defp check_signature_format(signature) do
    if String.starts_with?(signature, @signature_prefix) do
      {:ok, String.trim_leading(signature, @signature_prefix)}
    else
      {:error, %MalformedSignature{}}
    end
  end
end
