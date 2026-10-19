defmodule EventSourcingDB.Errors.CallTimedOut do
  @moduledoc """
  A call did not finish within the timeout that it was given as its
  `:timeout` option, so the client SDK aborted its request.

  For a call that returns a stream, the timeout includes reading the stream,
  which raises the error once the time runs out. A write that times out once
  its request had a connection returns the error as the `cause` of an
  `EventSourcingDB.Errors.OutcomeUnknown`, since EventSourcingDB may have
  stored it nonetheless.
  """

  defexception message: "Call timed out: the call did not finish within its timeout."

  @type t() :: %__MODULE__{message: String.t()}

  @doc false
  @spec new(pos_integer()) :: t()
  def new(timeout) when is_integer(timeout) do
    %__MODULE__{message: "Call timed out: the call did not finish within #{duration(timeout)}."}
  end

  defp duration(1_000), do: "1 second"

  defp duration(milliseconds) when rem(milliseconds, 1_000) == 0,
    do: "#{div(milliseconds, 1_000)} seconds"

  defp duration(1), do: "1 millisecond"
  defp duration(milliseconds), do: "#{milliseconds} milliseconds"
end
