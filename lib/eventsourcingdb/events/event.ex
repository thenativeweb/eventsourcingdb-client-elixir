defmodule EventSourcingDB.Event do
  @moduledoc """
  An Event coming from the server.
  """
  alias EventSourcingDB.Event

  alias EventSourcingDB.Errors.{
    HashVerificationFailed,
    MalformedSignature,
    SignatureMissing,
    SignatureVerificationFailed,
    UnsupportedHashVersion
  }

  use TypedStruct

  @signature_prefix "esdb:signature:v1:"

  # A hash that names its version starts with this prefix. A hash without it is
  # of version 1, which predates the prefix.
  @hash_prefix "esdb:hash:"
  @hash_v2_prefix "esdb:hash:v2:"

  # Stands for a field that the event does not have in the input of a hash of
  # version 2.
  @missing_field "-"

  typedstruct do
    @typedoc """
    An event as EventSourcingDB returns it.

    The field `__raw_data__` is an implementation detail and not part of the
    stable API: an event that the client SDK received from the server holds
    the JSON text of `data` there, exactly as it arrived, so that verifying the
    hash can use it byte for byte.
    """
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
    field :__raw_data__, String.t() | nil
  end

  @spec new(map()) :: Event.t()
  def new(value \\ %{}) do
    struct!(__MODULE__, value |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end))
  end

  # Creates an event from what the server returned, and keeps the JSON text of
  # its data as it arrived.
  @doc false
  @spec new(map(), String.t() | nil) :: Event.t()
  def new(value, raw_data) do
    %{new(value) | __raw_data__: raw_data}
  end

  @doc """
  Verifying an Event's Hash

  To verify the integrity of an event, call the `Event.verify_hash` function on the event. This recomputes the event's hash locally and compares it to the hash stored in the event. If the hashes differ, the function returns an `EventSourcingDB.Errors.HashVerificationFailed` error:

  ```elixir
  alias EventSourcingDB.Event

  case Event.verify_hash(event) do
   :ok -> # hash is valid
   {:error, reason} -> # ...
  end
  ```

  The hash tells which version of the hash it is, and an event keeps the version it was written with: a hash that starts with `esdb:hash:v2:` is of version 2, which EventSourcingDB writes since version 1.3, and a hash without such a prefix is of version 1. The function verifies both. A hash whose prefix names a version that this client SDK does not know, such as `esdb:hash:v3:`, can not be verified, so the function returns an `EventSourcingDB.Errors.UnsupportedHashVersion` error, which names the version, rather than report the event as tampered with.

  Both versions hash the data of the event exactly as EventSourcingDB sent it, byte for byte, which every event that the client SDK returns keeps for this purpose. For an event that you create yourself, for example with `Event.new/1`, only the decoded data is known, so the function encodes it again with Jason, which can differ from what EventSourcingDB sent, for example for `&`, `<`, and `>`, which EventSourcingDB escapes.

  Events that the client SDK returns carry this text in the field `__raw_data__`, so comparing such an event with `==` against one built with `Event.new/1` or a struct literal no longer matches, while pattern matching is unaffected.

  *Note that this only verifies the hash. If you also want to verify the signature, you can skip this step and call `verify_signature` directly, which performs a hash verification internally.*
  """
  @spec verify_hash(Event.t()) ::
          :ok | {:error, HashVerificationFailed.t()} | {:error, UnsupportedHashVersion.t()}
  def verify_hash(event) do
    case hash_version(event.hash) do
      :v1 -> compare_hash(event, compute_hash_v1(event))
      :v2 -> compare_hash(event, compute_hash_v2(event))
      {:unsupported, version} -> {:error, %UnsupportedHashVersion{version: version}}
    end
  end

  defp hash_version(@hash_v2_prefix <> _hash), do: :v2

  defp hash_version(@hash_prefix <> rest) do
    [version | _hash] = String.split(rest, ":", parts: 2)
    {:unsupported, version}
  end

  defp hash_version(_hash), do: :v1

  defp compare_hash(event, computed_hash) do
    if computed_hash == event.hash do
      :ok
    else
      {:error, %HashVerificationFailed{expected: event.hash, actual: computed_hash}}
    end
  end

  # Version 1 hashes the hash of the metadata, joined by vertical bars, and the
  # hash of the data together. It covers neither traceparent nor tracestate.
  defp compute_hash_v1(event) do
    metadata =
      "#{event.specversion}|#{event.id}|#{event.predecessorhash}|#{event.time}|#{event.source}|#{event.subject}|#{event.type}|#{event.datacontenttype}"

    metadata_hash = sha256_hex(metadata)
    data_hash = sha256_hex(encode_data(event))

    sha256_hex("#{metadata_hash}#{data_hash}")
  end

  # Version 2 hashes the prefix and every field, each on a line of its own,
  # without a line feed after the last one, and a missing field as a dash.
  defp compute_hash_v2(event) do
    input =
      Enum.join(
        [
          @hash_v2_prefix,
          event.specversion,
          event.id,
          event.predecessorhash,
          event.time,
          event.source,
          event.subject,
          event.type,
          event.datacontenttype,
          event.traceparent || @missing_field,
          event.tracestate || @missing_field,
          encode_data(event)
        ],
        "\n"
      )

    @hash_v2_prefix <> sha256_hex(input)
  end

  # Both versions hash the data exactly as the server sent it, which an event
  # that the client SDK received keeps as text. An event that was made
  # otherwise, for example with new/1, has only its decoded data, so it is
  # hashed as Jason encodes it again.
  defp encode_data(%Event{__raw_data__: raw_data}) when is_binary(raw_data), do: raw_data
  defp encode_data(event), do: Jason.encode!(event.data)

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifying an Event's Signature

  To verify the authenticity of an event, call the `Event.verify_signature` function on the event. This requires the public key that matches the private key used for signing on the server.

  The function first verifies the event's hash, and then checks the signature. If any verification step fails, it returns an error, for example an `EventSourcingDB.Errors.HashVerificationFailed` error if the hash is invalid, an `EventSourcingDB.Errors.UnsupportedHashVersion` error if the hash is of a version that this client SDK does not know, or an `EventSourcingDB.Errors.SignatureVerificationFailed` error if the signature is invalid:

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
          | {:error, UnsupportedHashVersion.t()}
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
