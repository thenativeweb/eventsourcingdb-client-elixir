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
  alias EventSourcingDB.Errors.{DbApiError, OutcomeUnknown, TransmissionError}

  # The statuses with which the v2 API refuses a request before it stores
  # anything.
  @v2_refusals [400, 401, 408, 413, 429, 503]

  # The reasons of a failure to connect, before the request was sent: the
  # name could not be resolved, nobody accepted the connection, or TLS failed.
  @connect_failures [
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :eaddrnotavail,
    :protocol_not_negotiated
  ]

  @spec classify(result, :v1 | :v2) :: result
        when result: {:ok, any()} | {:error, Exception.t()}
  def classify({:error, reason}, api) do
    if certainly_not_stored?(reason, api) do
      {:error, reason}
    else
      {:error, %OutcomeUnknown{cause: reason}}
    end
  end

  def classify(result, _api), do: result

  @spec certainly_not_stored?(Exception.t(), :v1 | :v2) :: boolean()
  def certainly_not_stored?(%TransmissionError{reason: reason}, _api), do: not_connected?(reason)

  # A domain error of the v2 API, which arrives at status 200, refuses the
  # write, except for store-failed, with which the store itself failed.
  def certainly_not_stored?(%DbApiError{status: 200, code: code}, :v2),
    do: code != ErrorCode.store_failed()

  def certainly_not_stored?(%DbApiError{status: status}, :v2), do: status in @v2_refusals

  def certainly_not_stored?(%DbApiError{status: status}, :v1),
    do: status in 400..499 or status in [503, 507]

  def certainly_not_stored?(_reason, _api), do: false

  defp not_connected?(%Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:disconnected, :connection_not_ready]

  defp not_connected?(%{__exception__: true, reason: {:tls_alert, _alert}}), do: true
  defp not_connected?(%{__exception__: true, reason: {:bad_alpn_protocol, _protocol}}), do: true
  defp not_connected?(%{__exception__: true, reason: reason}), do: reason in @connect_failures
  defp not_connected?(_reason), do: false
end
