defmodule EventSourcingDB.Transport.Deadline do
  @moduledoc false

  # The time by which a call that was given a timeout has to finish. The
  # requests of the call, and the stream that it returns, if it returns one,
  # check the deadline, so that the call ends with an
  # EventSourcingDB.Errors.CallTimedOut once the time ran out. A call without
  # a timeout has no deadline, which is nil.

  alias EventSourcingDB.Errors.CallTimedOut

  @enforce_keys [:at, :timeout]
  defstruct [:at, :timeout]

  @type t() :: %__MODULE__{at: integer(), timeout: pos_integer()}

  @spec new(pos_integer() | nil) :: t() | nil
  def new(nil), do: nil
  def new(timeout), do: %__MODULE__{at: now() + timeout, timeout: timeout}

  # How many milliseconds are left until the deadline.
  @spec remaining(t() | nil) :: timeout()
  def remaining(nil), do: :infinity
  def remaining(%__MODULE__{at: at}), do: max(at - now(), 0)

  @spec passed?(t() | nil) :: boolean()
  def passed?(deadline), do: remaining(deadline) == 0

  # The earlier of a point in time, in milliseconds of the monotonic clock,
  # and the deadline.
  @spec earliest(integer() | :infinity, t() | nil) :: integer() | :infinity
  def earliest(time, nil), do: time
  def earliest(time, %__MODULE__{at: at}), do: min(time, at)

  @spec error(t()) :: CallTimedOut.t()
  def error(%__MODULE__{timeout: timeout}), do: CallTimedOut.new(timeout)

  defp now, do: System.monotonic_time(:millisecond)
end
