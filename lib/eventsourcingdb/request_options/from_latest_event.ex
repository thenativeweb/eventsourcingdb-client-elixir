defmodule Eventsourcingdb.FromLatestEventOptions do
  @moduledoc """
  Reading events from when a certain event occured.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :if_event_is_missing, :read_everything | :read_nothing | :wait_for_event
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
    @spec encode(Eventsourcingdb.FromLatestEventOptions.t(), Jason.Encode.opts()) ::
            iodata()
    def encode(value, opts) do
      Jason.Encode.map(
        %{
          "ifEventIsMissing" =>
            case value.if_event_is_missing do
              :read_everything -> "read-everything"
              :read_nothing -> "read-nothing"
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
