defmodule Eventsourcingdb.Events.Event do
  defstruct [
    :data,
    :datacontenttype,
    :hash,
    :id,
    :predecessorhash,
    :signutare,
    :source,
    :specversion,
    :subject,
    :time,
    :type
  ]

  def new(value \\ []) do
    struct!(__MODULE__, value)
  end
end
