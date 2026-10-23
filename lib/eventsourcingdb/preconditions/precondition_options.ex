defmodule EventSourcingDB.PreconditionOptions do
  @moduledoc """
  Options for the preconditions on a subject: `EventSourcingDB.IsSubjectPristine`,
  `EventSourcingDB.IsSubjectPopulated`, and `EventSourcingDB.IsSubjectOnEventId`.

  With `recursive` set to `true`, the precondition checks the subject together
  with all subjects nested under it, as reading events recursively does, and
  with `recursive` set to `false`, the subject alone, as without options.
  Checking recursively requires a server with the v2 API.
  """
  use TypedStruct

  @derive Jason.Encoder
  typedstruct do
    field :recursive, boolean(), enforce: true
  end

  @spec new(keyword()) :: t()
  def new(options) do
    options =
      options
      |> Keyword.validate!([:recursive])

    struct!(__MODULE__, options)
  end

  # The v2 API refuses JSON null, so the payload of a precondition without
  # options leaves them out, which also keeps it as it was before preconditions
  # had options.
  @doc false
  @spec add_to_payload(map(), t() | nil) :: map()
  def add_to_payload(payload, nil), do: payload
  def add_to_payload(payload, options), do: Map.put(payload, "options", options)
end
