defmodule EventSourcingDB.ReadSubjectsOptions do
  @moduledoc """
  Read subjects options

  The `recursive` option is required: `true` lists the subject together with
  all subjects nested under it, `false` lists the subject alone.
  """
  use TypedStruct

  typedstruct do
    field :recursive, boolean(), enforce: true
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options = Keyword.validate!(options, [:recursive])

    case Keyword.fetch(options, :recursive) do
      {:ok, recursive} when is_boolean(recursive) ->
        %__MODULE__{recursive: recursive}

      _other ->
        raise ArgumentError,
              "expected :recursive to be true or false, got: #{inspect(options[:recursive])}"
    end
  end
end
