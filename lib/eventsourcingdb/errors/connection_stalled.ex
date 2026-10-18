defmodule EventSourcingDB.Errors.ConnectionStalled do
  @moduledoc """
  A request waited for the server for the stall timeout of the client without
  anything arriving, while connecting, while waiting for the response
  headers, or while waiting for the rest of the response.
  """

  defexception message: "Connection stalled: nothing arrived from the server for 30 seconds."

  @type t() :: %__MODULE__{message: String.t()}

  @doc false
  @spec new(timeout()) :: t()
  def new(timeout) when is_integer(timeout) do
    %__MODULE__{
      message: "Connection stalled: nothing arrived from the server for #{duration(timeout)}."
    }
  end

  def new(_timeout) do
    %__MODULE__{message: "Connection stalled: nothing arrived from the server."}
  end

  defp duration(1_000), do: "1 second"

  defp duration(milliseconds) when rem(milliseconds, 1_000) == 0,
    do: "#{div(milliseconds, 1_000)} seconds"

  defp duration(1), do: "1 millisecond"
  defp duration(milliseconds), do: "#{milliseconds} milliseconds"
end
