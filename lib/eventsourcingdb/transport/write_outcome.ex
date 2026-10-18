defmodule EventSourcingDB.Transport.WriteOutcome do
  @moduledoc false

  # Tells whether a write that failed, writing events or registering an event
  # schema, was certainly not stored, or may have been stored nonetheless, by
  # the same rule in every official client SDK. EventSourcingDB never stores a
  # write halfway, so a write whose answer is lost may have been stored
  # completely.
  #
  # A write was certainly not stored only if the connection could not be
  # established at all, or if the server refused it explicitly. Everything
  # else leaves the outcome open: a stall, a broken connection after
  # connecting, a stream of the v2 API that ends without its end item, a 500,
  # a 502 or 504, or any answer that is not from an EventSourcingDB.

  alias EventSourcingDB.ErrorCode
  alias EventSourcingDB.Errors.{DbApiError, OutcomeUnknown}

  # The statuses with which the v2 API refuses a request before it stores
  # anything.
  @v2_refusals [400, 401, 408, 413, 429, 503]

  # A request that failed before it was sent, as the transport tells, was not
  # stored. Once it was sent, or once it may have been, the write was not
  # stored only if the server refused it explicitly, whatever the reason of
  # another failure: a connection may well break with a TLS alert or an
  # unreachable host after the server stored the write.
  @spec classify(result, :v1 | :v2) :: result
        when result: {:ok, any()} | {:error, Exception.t() | {:not_sent, Exception.t()}}
  def classify({:error, {:not_sent, reason}}, _api), do: {:error, reason}

  def classify({:error, reason}, api) do
    if refused?(reason, api) do
      {:error, reason}
    else
      {:error, %OutcomeUnknown{cause: reason}}
    end
  end

  def classify(result, _api), do: result

  # A domain error of the v2 API, which arrives at status 200, refuses the
  # write, except for store-failed, with which the store itself failed.
  defp refused?(%DbApiError{status: 200, code: code}, :v2), do: code != ErrorCode.store_failed()
  defp refused?(%DbApiError{status: status}, :v2), do: status in @v2_refusals
  defp refused?(%DbApiError{status: status}, :v1), do: status in 400..499 or status in [503, 507]
  defp refused?(_reason, _api), do: false
end
