defmodule Eventsourcingdb.RequestOptions do
  use TypedStruct

  defmodule FromLatestEventOptions do
    typedstruct enforce: true do
      field :if_event_is_missing, :read_everything | :read_nothing
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
      @spec encode(Eventsourcingdb.RequestOptions.FromLatestEventOptions.t(), Jason.Encode.opts()) ::
              iodata()
      def encode(value, opts) do
        Jason.Encode.map(
          %{
            "ifEventIsMissing" =>
              case value.if_event_is_missing do
                :read_everything -> "read-everything"
                :read_nothing -> "read-nothing"
              end,
            "subject" => value.subject,
            "type" => value.type
          },
          opts
        )
      end
    end
  end

  defmodule BoundOptions do
    @derive Jason.Encoder
    typedstruct enforce: true do
      field :id, String.t()
      field :type, :inclusive | :exclusive
    end

    @spec new(keyword()) :: t()
    def new(options) do
      options =
        options
        |> Keyword.validate!([:id, :type])

      struct!(__MODULE__, options)
    end
  end
end
