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

  # Whether only the v2 API checks the precondition as it asks. The v1 API
  # checks every precondition on the subject alone, which is what a
  # precondition without options, or with recursive set to false, asks for,
  # so every other options need the v2 API, even ones that are not valid,
  # rather than be checked on the subject alone without notice.
  @doc false
  @spec needs_v2_api?(struct()) :: boolean()
  def needs_v2_api?(%{options: nil}), do: false
  def needs_v2_api?(%{options: %__MODULE__{recursive: false}}), do: false
  def needs_v2_api?(%{options: _options}), do: true
  def needs_v2_api?(_precondition), do: false
end
