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
end
