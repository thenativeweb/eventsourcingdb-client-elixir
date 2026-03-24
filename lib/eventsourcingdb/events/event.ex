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

  @key_mapping %{
    "predecessorhash" => :predecessor_hash,
    "datacontenttype" => :data_content_type,
    "specversion" => :spec_version
  }

  typedstruct do
    field :data, any(), enforce: true
    field :data_content_type, String.t(), enforce: true
    field :hash, String.t(), enforce: true
    field :id, String.t(), enforce: true
    field :predecessor_hash, String.t(), enforce: true
    field :signature, String.t()
    field :source, String.t(), enforce: true
    field :spec_version, String.t(), enforce: true
    field :subject, String.t(), enforce: true
    field :time, String.t(), enforce: true
    field :traceparent, String.t()
    field :tracestate, String.t()
    field :type, String.t(), enforce: true
  end

  @spec new(map()) :: Event.t()
  def new(value \\ %{}) do
    struct!(
      __MODULE__,
      value
      |> Map.new(fn {k, v} ->
        key = Map.get_lazy(@key_mapping, k, fn -> String.to_existing_atom(k) end)
        {key, v}
      end)
    )
  end

  @doc """
  Verifying an Event's Hash

  To verify the integrity of an event, call the `Event.verify_hash` function on the event. This recomputes the event's hash locally and compares it to the hash stored in the event. If the hashes differ, the function returns an error:

  ```elixir
  alias EventSourcingDB.Event

  case Event.verify_hash(event) do
   :ok -> # hash is valid
   {:error, reason} -> # ...
  end
  ```

  *Note that this only verifies the hash. If you also want to verify the signature, you can skip this step and call `verify_signature` directly, which performs a hash verification internally.*
  """
  @spec verify_hash(Event.t()) :: :ok | {:error, HashVerificationFailed.t()}
  def verify_hash(event) do
    metadata =
      "#{event.spec_version}|#{event.id}|#{event.predecessor_hash}|#{event.time}|#{event.source}|#{event.subject}|#{event.type}|#{event.data_content_type}"

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

  @doc """
  Verifying an Event's Signature

  To verify the authenticity of an event, call the `Event.verify_signature` function on the event. This requires the public key that matches the private key used for signing on the server.

  The function first verifies the event's hash, and then checks the signature. If any verification step fails, it returns an error:

  ```elixir
  alias EventSourcingDB.Event

  verification_key = # public key as Ed25519 binary

  case Event.verify_signature(event, verification_key) do
    :ok -> # signature is valid
    {:error, reason} -> # ...
  end
  ```
  """
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
