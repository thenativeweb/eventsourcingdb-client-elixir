defmodule EventSourcingDB.ErrorCode do
  @moduledoc """
  The codes of the errors that EventSourcingDB reports, as the `code` of an
  `EventSourcingDB.Errors.DbApiError`.

  Each code is a URL, which leads to the documentation of the error. Every
  function returns one code, and is named after the last part of the URL, so
  that `precondition_violated/0` returns
  `https://docs.eventsourcingdb.io/errors/precondition-violated`:

  ```elixir
  case EventSourcingDB.write_events(client, events, preconditions) do
    {:ok, events} ->
      # ...

    {:error, %EventSourcingDB.Errors.DbApiError{code: code}} ->
      if code == EventSourcingDB.ErrorCode.precondition_violated() do
        # ...
      end
  end
  ```

  To match a code in a pattern, read it into a module attribute first:

  ```elixir
  @precondition_violated EventSourcingDB.ErrorCode.precondition_violated()

  def handle({:error, %EventSourcingDB.Errors.DbApiError{code: @precondition_violated}}), do: # ...
  ```

  Servers without the v2 API report errors without codes. For the errors that
  clearly match one, the client SDK assigns the code of the v2 API itself.
  """

  @base_url "https://docs.eventsourcingdb.io/errors/"

  # The slugs as EventSourcingDB lists them, in cmd/server/api/error.go.
  @slugs ~w(
    subject-missing
    subject-malformed
    order-unknown
    event-id-missing
    event-id-malformed
    bound-type-missing
    bound-type-unknown
    range-unsatisfiable
    from-latest-event-incomplete
    if-event-is-missing-unknown
    selection-conflicting
    event-type-missing
    event-type-malformed
    event-type-unknown
    source-missing
    source-malformed
    data-missing
    traceparent-malformed
    tracestate-malformed
    tracestate-without-traceparent
    events-missing
    precondition-type-missing
    precondition-unknown
    payload-missing
    license-invalid
    capacity-exceeded
    event-schema-violated
    event-schema-unregistered
    event-schema-missing
    event-schema-malformed
    event-schema-not-object
    event-schema-already-registered
    last-audited-event-missing
    last-audited-event-mismatched
    last-audited-event-unknown
    event-hash-missing
    event-hash-malformed
    event-chain-broken
    last-backed-up-event-missing
    last-backed-up-event-mismatched
    last-backed-up-event-unknown
    store-not-empty
    event-hash-version-unknown
    backup-malformed
    backup-incomplete
    backup-format-unknown
    full-backup-missing
    backup-increment-disconnected
    backup-failed
    backup-unreadable
    event-too-large
    data-malformed
    query-missing
    query-malformed
    query-unevaluable
    query-not-boolean
    precondition-violated
    store-read-only
    read-only-mode-already-enabled
    disk-full
    restore-in-progress
    store-failed
    indexes-rebuilding
    server-shutting-down
  )

  for slug <- @slugs do
    @doc "Returns `#{@base_url}#{slug}`."
    @spec unquote(slug |> String.replace("-", "_") |> String.to_atom())() :: String.t()
    def unquote(slug |> String.replace("-", "_") |> String.to_atom())(),
      do: unquote(@base_url <> slug)
  end

  @doc """
  Returns every code that EventSourcingDB reports.
  """
  @spec all() :: [String.t()]
  def all(), do: Enum.map(@slugs, &(@base_url <> &1))
end
