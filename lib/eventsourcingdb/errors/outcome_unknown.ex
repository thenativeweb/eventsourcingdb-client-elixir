defmodule EventSourcingDB.Errors.OutcomeUnknown do
  @moduledoc """
  Writing events or registering an event schema failed in a way that leaves
  open whether the server stored the write, for example because the
  connection stalled or broke after the request was sent.

  EventSourcingDB never stores a write halfway, so the write was either
  stored completely or not at all. Before repeating it, find out which, for
  example by reading the events of the subject.

  - `:cause` - The error that made the request fail
  """

  defexception [:cause]

  @type t() :: %__MODULE__{cause: Exception.t()}

  @impl true
  def message(%__MODULE__{cause: cause}) do
    "Outcome unknown: the write may have been stored. Cause: #{Exception.message(cause)}"
  end
end
