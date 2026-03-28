defmodule EventSourcingDB.ObserveFromLatestEventOptions do
  @moduledoc """
  Options for observing events starting from the latest event of a given type.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :if_event_is_missing, :read_everything | :wait_for_event
    field :subject, String.t()
    field :type, String.t()
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options =
      options
      |> Keyword.validate!([:if_event_is_missing, :subject, :type])

    struct!(__MODULE__, options)
  end

  defimpl Jason.Encoder do
    @spec encode(EventSourcingDB.ObserveFromLatestEventOptions.t(), Jason.Encode.opts()) ::
            iodata()
    def encode(value, opts) do
      Jason.Encode.map(
        %{
          "ifEventIsMissing" =>
            case value.if_event_is_missing do
              :read_everything -> "read-everything"
              :wait_for_event -> "wait-for-event"
            end,
          "subject" => value.subject,
          "type" => value.type
        },
        opts
      )
    end
  end
end
