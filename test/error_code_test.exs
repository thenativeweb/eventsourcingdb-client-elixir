defmodule EventSourcingDBTest.ErrorCode do
  alias EventSourcingDB.ErrorCode
  use ExUnit.Case, async: true

  # The slugs of the errors that EventSourcingDB lists in
  # cmd/server/api/error.go, as of commit 63877b24 on main.
  @server_slugs ~w(
    subject-missing subject-malformed subject-too-long subject-too-deep order-unknown
    event-id-missing event-id-malformed bound-type-missing bound-type-unknown range-unsatisfiable
    from-latest-event-incomplete if-event-is-missing-unknown selection-conflicting
    event-type-missing event-type-malformed event-type-unknown source-missing source-malformed
    data-missing traceparent-malformed tracestate-malformed tracestate-without-traceparent
    events-missing precondition-type-missing precondition-unknown payload-missing license-invalid
    capacity-exceeded event-schema-violated event-schema-unregistered event-schema-missing
    event-schema-malformed event-schema-not-object event-schema-too-complex
    event-schema-already-registered last-audited-event-missing last-audited-event-mismatched
    last-audited-event-unknown event-hash-missing event-hash-malformed event-chain-broken
    last-backed-up-event-missing last-backed-up-event-mismatched last-backed-up-event-unknown
    store-not-empty event-hash-version-unknown backup-malformed backup-incomplete
    backup-format-unknown full-backup-missing backup-increment-disconnected backup-failed
    backup-unreadable backup-ahead-of-clock import-ahead-of-clock import-malformed
    import-unreadable event-too-large data-malformed query-missing query-malformed query-too-deep
    query-too-long query-unevaluable query-not-boolean precondition-violated store-read-only
    read-only-mode-already-enabled disk-full restore-in-progress store-failed indexes-rebuilding
    server-shutting-down file-unreadable
  )

  @base_url "https://docs.eventsourcingdb.io/errors/"

  test "lists every code of the server, and nothing else" do
    assert ErrorCode.all() == Enum.map(@server_slugs, &(@base_url <> &1))
  end

  test "names each code after its slug" do
    for slug <- @server_slugs do
      name = slug |> String.replace("-", "_") |> String.to_atom()

      assert apply(ErrorCode, name, []) == @base_url <> slug
    end
  end

  test "names no code that the server does not list" do
    names =
      for slug <- @server_slugs,
          do: {slug |> String.replace("-", "_") |> String.to_atom(), 0}

    assert Enum.sort(ErrorCode.__info__(:functions) -- [all: 0]) == Enum.sort(names)
  end
end
