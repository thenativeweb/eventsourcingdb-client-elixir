defmodule EventSourcingDB.Transport.HTTP do
  @moduledoc false

  # The HTTP machinery that every API shares: building a request, sending a
  # request with a single answer, and opening and reading a stream of NDJSON
  # lines, each bounded by the stall timeout of the client.
  #
  # A call that was given a timeout passes its deadline as the option
  # :deadline, which bounds the request with a single answer as a whole, and
  # the stream from opening it to reading its last line. Once the deadline
  # passed, the request is aborted, and the call fails with an
  # EventSourcingDB.Errors.CallTimedOut, while the stall timeout keeps
  # bounding each wait for data with an error of its own.

  alias EventSourcingDB.Client
  alias EventSourcingDB.Transport.{Deadline, RequestPhase}

  alias EventSourcingDB.Errors.{
    CallTimedOut,
    ConnectionStalled,
    DbApiError,
    InvalidResponseType,
    InvalidServerHeader,
    TransmissionError
  }

  # The relay carries the OpenTelemetry context of the caller over if
  # OpenTelemetry is in use, without depending on it.
  @compile {:no_warn_undefined, :otel_ctx}

  @default_stall_timeout 30_000

  @typedoc """
  Turns an item of a stream, decoded from its line, which is given as well, as
  it arrived, into what the stream yields, or tells to skip it, to end the
  stream, or to raise an error.
  """
  @type decoder() :: (map(), String.t() ->
                        {:item, any()} | :skip | :end | {:error, Exception.t()})

  #
  # region Requests with a single answer
  #

  # A request with a single answer waits for each block of data at most for
  # the receive timeout, and connecting at most for the connect timeout (see
  # build_request/5). The body is not decoded, so that each API decodes it as
  # it needs, for example events with the text of their data as it arrived,
  # for verifying their hash.
  #
  # With the option track_sending: true, a request that failed before it was
  # sent fails with {:not_sent, reason}, so that a write can tell that it was
  # not stored (see EventSourcingDB.Transport.RequestPhase). So does a request
  # that timed out before it had a connection.
  #
  # With the option answered, a function, the function is given the answer
  # before it is checked to come from EventSourcingDB, as for stream/5.
  @spec one_shot(Client.t(), atom(), String.t(), term(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def one_shot(client, method, path, body, options \\ []) do
    {answered, options} = Keyword.pop(options, :answered, &ignore_answer/1)

    with {:ok, response} <- unchecked_one_shot(client, method, path, body, options),
         answered.(response),
         :ok <- validate_server_header(response) do
      {:ok, response}
    end
  end

  defp ignore_answer(_response), do: :ok

  # Sends a request with a single answer as one_shot/5 does, but returns the
  # answer whether it comes from EventSourcingDB or not, for the caller to
  # check.
  @spec unchecked_one_shot(Client.t(), atom(), String.t(), term(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def unchecked_one_shot(client, method, path, body, options \\ []) do
    {track_sending?, options} = Keyword.pop(options, :track_sending, false)
    {deadline, options} = Keyword.pop(options, :deadline)
    req = build_request(client, method, path, body, options)
    timeout = receive_timeout(client, req)

    case request_one_shot(req, timeout, deadline) do
      {{:ok, response}, _phase} -> {:ok, response}
      {{:error, reason}, phase} -> failure(reason, timeout, phase, track_sending?)
      {:timed_out, connected?} -> timed_out(deadline, connected?, track_sending?)
    end
  end

  # Without a deadline, in a pool whose waits Finch bounds one by one (see
  # finch_bounds_each_wait?/1), the request runs in the calling process, and
  # Finch bounds each wait for data with the receive timeout. Every other
  # request runs through the relay, as a stream does (see
  # request_through_relay/3), and the caller reads the body of the response:
  #
  #   * With a deadline, so that the caller can abort the request at the
  #     deadline, which closes its connection, or resets its stream in an
  #     HTTP/2 pool.
  #   * In every other pool, such as an HTTP/2 pool, where Finch bounds the
  #     request as a whole, so that an answer whose data keeps arriving would
  #     end once the receive timeout has passed. There the request asks Finch
  #     for no timeout, and the caller bounds each wait itself, as for a
  #     stream.
  defp request_one_shot(req, timeout, deadline) do
    if deadline == nil and finch_bounds_each_wait?(req) do
      RequestPhase.track(fn -> Req.request(req, receive_timeout: timeout, decode_body: false) end)
    else
      request_one_shot_through_relay(req, timeout, deadline)
    end
  end

  defp request_one_shot_through_relay(req, timeout, deadline) do
    {relay_options, wait} =
      if finch_bounds_each_wait?(req),
        do: {[receive_timeout: timeout], :infinity},
        else: {[wait: relay_wait(timeout)], timeout}

    case request_through_relay(req, deadline, relay_options) do
      {{:ok, response}, phase} ->
        case read_body(response, wait, deadline, "") do
          {:ok, body} ->
            {{:ok, %{response | body: body}}, phase}

          {:error, %CallTimedOut{}} ->
            close_stream(response)
            {:timed_out, true}

          {:error, reason} ->
            close_stream(response)
            {{:error, reason}, :maybe_sent}
        end

      result ->
        result
    end
  end

  # A call that timed out fails with an error of its own, which, should the
  # caller ask for it, tells whether the request had no connection yet, in
  # which case it was certainly not sent.
  defp timed_out(deadline, connected?, track_sending?) do
    error = Deadline.error(deadline)

    if track_sending? and not connected?,
      do: {:error, {:not_sent, error}},
      else: {:error, error}
  end

  # A failure of the transport, which is a stall if it is a timeout, and,
  # should the caller ask for it, tells whether the request was not sent at
  # all: if Finch saw its connection fail, or the HTTP/2 pool refused it for a
  # connection it does not have, which Finch 0.24 reports as
  # :pool_not_available.
  defp failure(reason, timeout, phase, track_sending?) do
    error = transport_error(reason, timeout)

    if track_sending? and (phase == :not_sent or refused_by_http2_pool?(reason)),
      do: {:error, {:not_sent, error}},
      else: {:error, error}
  end

  defp refused_by_http2_pool?(%Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:disconnected, :connection_not_ready, :pool_not_available]

  defp refused_by_http2_pool?(_reason), do: false

  #
  # region Streams
  #

  # Opens a stream of NDJSON lines, and returns it once the server has
  # answered with status 200. The stream yields what the decoder makes of each
  # line. Its options:
  #
  #   * :decode - the decoder of the items
  #   * :heartbeats? - whether the server sends a heartbeat every second while
  #     it has nothing else to send
  #   * :ending - how the server ends the stream: :response, if the end of the
  #     response ends it, :end_item, if an end item ends it, which the server
  #     then must not leave out, or :never, if the server never ends it, as
  #     for observing events, so that the end of the response is a failure
  #   * :status_error - turns an answer with another status than 200, given as
  #     the response and the text of its body, into an error
  #   * :answered - is given the answer, whatever its status, before it is
  #     checked to come from EventSourcingDB
  #   * :track_sending - whether a stream that fails to open before it was
  #     sent fails with {:not_sent, reason}, as for one_shot/5
  #   * :deadline - the deadline of a call that was given a timeout, which
  #     bounds the stream from opening it to reading its last line
  @spec stream(Client.t(), atom(), String.t(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Exception.t()}
  def stream(client, method, path, body, options) do
    req = build_request(client, method, path, body, [])
    heartbeats? = Keyword.fetch!(options, :heartbeats?)

    stall_timeout =
      if heartbeats?, do: heartbeat_timeout(client), else: receive_timeout(client, req)

    opening = %{
      heartbeats?: heartbeats?,
      answered: Keyword.get(options, :answered, &ignore_answer/1),
      status_error: Keyword.get(options, :status_error, &default_status_error/2),
      track_sending?: Keyword.get(options, :track_sending, false),
      deadline: Keyword.get(options, :deadline)
    }

    case open_stream(req, stall_timeout, opening) do
      {:ok, response, wait} ->
        # The resource receives the lines of the response, and keeps the start
        # of a line that has not arrived completely yet next to the response.
        # Errors while the stream is read are raised, also while a line is
        # handled, so the stream always hands the response to the cleanup,
        # which closes the connection.
        state = %{
          response: response,
          rest: "",
          wait: wait,
          stall_timeout: stall_timeout,
          decode: Keyword.fetch!(options, :decode),
          ending: Keyword.fetch!(options, :ending),
          deadline: opening.deadline,
          status: :open
        }

        {:ok, Stream.resource(fn -> state end, &receive_items/1, &close_stream(&1.response))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Opens the stream, and returns how long the stream waits for each block of
  # the response itself. In an HTTP/1 pool, Finch bounds each wait for data
  # with the receive timeout, including the wait for the response headers, and
  # connecting with the connect timeout (see build_request/5), so a stream
  # without heartbeats leaves both to Finch. A stream with heartbeats fails
  # once nothing arrives for the stall timeout, so Finch must not end it first
  # with an error of its own, and it bounds each wait itself, in the relay, as
  # does every stream in a pool whose waits Finch does not bound one by one
  # (see finch_bounds_each_wait?/1). A stream of a call with a deadline takes
  # the relay as well, so that the caller can abort it while it opens.
  defp open_stream(req, stall_timeout, opening) do
    {response, wait} =
      if opening.deadline == nil and not opening.heartbeats? and finch_bounds_each_wait?(req) do
        {{Req.request(req, into: :self, receive_timeout: stall_timeout), :maybe_sent}, :infinity}
      else
        {request_through_relay(req, opening.deadline, wait: relay_wait(stall_timeout)),
         stall_timeout}
      end

    case response do
      {{:ok, response}, _phase} ->
        opening.answered.(response)
        validate_stream_response(response, stall_timeout, wait, opening)

      {{:error, reason}, phase} ->
        failure(reason, stall_timeout, phase, opening.track_sending?)

      {:timed_out, connected?} ->
        timed_out(opening.deadline, connected?, opening.track_sending?)
    end
    |> case do
      {:ok, response} -> {:ok, response, wait}
      error -> error
    end
  end

  # A stream that fails to open closes its response right away, so that none
  # of its messages stay behind in the mailbox.
  defp validate_stream_response(response, stall_timeout, wait, opening) do
    with :ok <- validate_server_header(response),
         :ok <- validate_stream_status(response, stall_timeout, wait, opening) do
      {:ok, response}
    else
      error ->
        close_stream(response)
        error
    end
  end

  # For a status other than 200, the error carries the text that the server
  # sent, as for the requests with a single answer, so the body is read before
  # the response is closed.
  defp validate_stream_status(%Req.Response{status: 200}, _stall_timeout, _wait, _opening),
    do: :ok

  defp validate_stream_status(response, stall_timeout, wait, opening) do
    case read_body(response, wait, opening.deadline, "") do
      {:ok, text} -> {:error, opening.status_error.(response, text)}
      {:error, reason} -> {:error, transport_error(reason, stall_timeout)}
    end
  end

  defp default_status_error(response, text), do: DbApiError.from_response(response, text)

  # Reads the rest of the body, and waits for each block of it at most for the
  # timeout, unless Finch bounds the wait, and until the deadline of the call.
  defp read_body(response, wait, call_deadline, body) do
    case receive_message(response, Deadline.earliest(deadline(wait), call_deadline)) do
      {:ok, [data: data]} -> read_body(response, wait, call_deadline, body <> data)
      {:ok, [:done]} -> {:ok, body}
      {:ok, _other} -> read_body(response, wait, call_deadline, body)
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, timeout_reason(call_deadline)}
    end
  end

  # A wait that ended at the deadline of the call ends the call, and every
  # other one is a stall.
  defp timeout_reason(call_deadline) do
    if Deadline.passed?(call_deadline),
      do: Deadline.error(call_deadline),
      else: %Req.TransportError{reason: :timeout}
  end

  # Every block of the response restarts the timeout, since anything that
  # arrives shows that the connection is alive, so the start of a line that
  # has not arrived completely yet restarts it as well. The data of the
  # response arrives in blocks, which need not match the lines: a block may
  # hold several lines, and a long line may span several blocks. So the start
  # of a line waits in the state until the rest of it arrives.
  #
  # Errors are raised rather than returned, because Stream.resource takes a
  # returned {:error, reason} for a list of items. Raising ends the stream,
  # which cancels the response and thereby closes the connection. An error
  # that a line reports is raised once the items of the lines before it have
  # been delivered.
  #
  # The deadline of a call ends the stream as a stall does, also while the
  # lines arrive faster than the stream is read.
  defp receive_items(%{status: :ended} = state), do: {:halt, state}
  defp receive_items(%{status: {:failed, reason}}), do: raise(reason)

  defp receive_items(state) do
    if Deadline.passed?(state.deadline), do: raise(Deadline.error(state.deadline))

    case receive_message(state.response, Deadline.earliest(deadline(state.wait), state.deadline)) do
      {:ok, [data: data]} ->
        case split_lines(state.rest, data) do
          {[], rest} -> receive_items(%{state | rest: rest})
          {lines, rest} -> handle_lines(lines, %{state | rest: rest})
        end

      # EventSourcingDB ends every line with a newline, including the last one.
      # Still, a rest at the end of the response is a line as well.
      {:ok, [:done]} ->
        {lines, ""} = split_lines(state.rest, "\n")
        {items, state} = handle_lines(lines, %{state | rest: ""})
        {items, finish(state)}

      # Other messages of the response, such as trailing headers, carry no
      # line.
      {:ok, _other} ->
        receive_items(state)

      {:error, reason} ->
        raise(transport_error(reason, state.stall_timeout))

      :timeout ->
        raise(transport_error(timeout_reason(state.deadline), state.stall_timeout))
    end
  end

  # A stream that the server ends with an end item fails if the response ends
  # before that item, and a stream that the server never ends fails if the
  # response ends at all, since the server then broke it off. A server that
  # shuts down says so with an error item first.
  defp finish(%{status: :open, ending: :response} = state), do: %{state | status: :ended}
  defp finish(%{status: :open} = state), do: %{state | status: {:failed, broken_off_error()}}
  defp finish(state), do: state

  @doc false
  @spec broken_off_error() :: Exception.t()
  def broken_off_error() do
    %TransmissionError{reason: %RuntimeError{message: "the server ended the stream unexpectedly"}}
  end

  # Splits the data at each newline into the lines it completes, the first of
  # which begins with the rest of the data before, and a new rest, the start of
  # a line whose newline has not arrived yet. Empty lines are skipped, and data
  # without a newline, such as the empty data frame with which EventSourcingDB
  # ends a response over HTTP/2, completes no line.
  defp split_lines(rest, data) do
    [first | others] = String.split(data, "\n")
    {lines, [rest]} = Enum.split([rest <> first | others], -1)

    {Enum.reject(lines, &(&1 == "")), rest}
  end

  # Decodes the lines one after another, until one of them ends the stream or
  # reports an error, which then waits in the state.
  defp handle_lines(lines, state) do
    {items, state} =
      Enum.reduce_while(lines, {[], state}, fn line, {items, state} ->
        case decode_line(line, state.decode) do
          {:item, item} -> {:cont, {[item | items], state}}
          :skip -> {:cont, {items, state}}
          :end -> {:halt, {items, %{state | status: :ended}}}
          {:error, reason} -> {:halt, {items, %{state | status: {:failed, reason}}}}
        end
      end)

    {Enum.reverse(items), state}
  end

  defp decode_line(line, decode) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = item} when is_binary(type) ->
        decode.(item, line)

      {:ok, _item} ->
        {:error, %InvalidResponseType{expected: "an item with a type", actual: line}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Waits for the next message of the response. Finch tags every message of the
  # response with the reference of the request, so only these are received,
  # and all other messages of the process stay in its mailbox. They do not
  # come from the server, so they do not restart the timeout either.
  defp receive_message(%Req.Response{body: %Req.Response.Async{ref: ref}} = response, deadline) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          # Req does not recognise every message of the response, for example
          # trailing headers over HTTP/2. They carry no line, so they are
          # skipped.
          :unknown -> receive_message(response, deadline)
          result -> result
        end
    after
      remaining_time(deadline) -> :timeout
    end
  end

  # Closes the connection, and cleans up the messages of the response that are
  # left in the mailbox.
  defp close_stream(response) do
    case Req.Response.get_private(response, :relay) do
      nil -> :ok
      relay -> stop_relay(relay, Process.monitor(relay))
    end

    Req.cancel_async_response(response)
  end

  # A transport error that is a timeout is a stall, since every timeout is
  # the stall timeout of the request, while the deadline of a call ends it
  # with an error of its own.
  @doc false
  @spec transport_error(Exception.t(), timeout()) :: Exception.t()
  def transport_error(%CallTimedOut{} = error, _timeout), do: error

  def transport_error(%{__exception__: true, reason: :timeout}, timeout) do
    ConnectionStalled.new(timeout)
  end

  def transport_error(reason, _timeout), do: %TransmissionError{reason: reason}

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining_time(:infinity), do: :infinity
  defp remaining_time(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  #
  # region Timeouts
  #

  # How long a stream with heartbeats waits for anything to arrive: the stall
  # timeout of the client, or else 30 seconds, as the heartbeat timeout always
  # was.
  defp heartbeat_timeout(client), do: client.stall_timeout || @default_stall_timeout

  # How long every other request waits for anything to arrive: the stall
  # timeout of the client, or else the receive timeout that the client passes
  # on to Req, as it always has, including :infinity, or else 30 seconds. The
  # options of the client are read for every request, so that a client whose
  # options change behaves accordingly.
  defp receive_timeout(client, req) do
    client.stall_timeout || Req.Request.get_option(req, :receive_timeout, @default_stall_timeout)
  end

  # Finch bounds each wait for data with the receive timeout only in an HTTP/1
  # pool, and the whole request in an HTTP/2 pool. Req starts an HTTP/2 pool if
  # the protocols leave out HTTP/1 (with both, the protocol is negotiated per
  # connection within an HTTP/1 pool). The protocols of a pool that the client
  # brings by name are unknown, so the client SDK bounds each wait itself
  # there, whether the pool speaks HTTP/1 or HTTP/2.
  defp finch_bounds_each_wait?(req) do
    case Req.Request.get_option(req, :finch) do
      nil ->
        http1_pool?(req, [])

      options when is_list(options) ->
        not Keyword.has_key?(options, :name) and http1_pool?(req, options)

      _name ->
        false
    end
  end

  # Req takes the protocols from the Finch options, or else from the connection
  # options.
  defp http1_pool?(req, finch_options) do
    protocols =
      Keyword.get_lazy(finch_options, :protocols, fn ->
        Req.Finch.pool_options(req.options)[:protocols]
      end)

    :http1 in protocols
  end

  #
  # region Relay
  #

  # Over HTTP/2, Finch bounds a whole request with the receive timeout, rather
  # than each wait for data, so a stream, or an answer, that runs for longer
  # would end while data still arrives, and in an HTTP/1 pool, the receive
  # timeout would end a stream with heartbeats with an error of its own. So
  # such a request asks Finch for no timeout, and bounds each wait itself: the
  # wait for the response headers here, from sending the request, and the wait
  # for each block of the response in receive_items/1, or in read_body/4 for
  # a request with a single answer. Req then waits for the response headers
  # in a receive without any bound, which the caller can not interrupt, so
  # the request runs in a relay process, which forwards the messages of the
  # response to the caller, while the caller bounds the wait. A pool that the
  # client brings by name takes this path as well, even one that speaks
  # HTTP/1, where Finch then waits for data without a bound, too. So do the
  # requests of a call with a deadline, so that the caller can stop the relay
  # once the deadline passed, where a request with a single answer in an
  # HTTP/1 pool leaves the waits for data to Finch, as it does in the calling
  # process.
  #
  # The relay is linked to the caller while it waits for the response headers,
  # and monitors it afterwards, so it does not outlive the caller. Finch in turn
  # cancels the request once the relay is down.
  #
  # The caller waits for the response headers at most for the given wait, and
  # until the deadline of the call, while Finch waits for each block of data
  # at most for the given receive timeout, which is :infinity unless Finch
  # bounds the waits of a request with a single answer. A request whose wait
  # ran out before it had a connection, which an HTTP/1 pool tells, was not
  # sent, for example in a pool that the client brings by name, which may
  # take longer to connect than the stall timeout.
  defp request_through_relay(req, deadline, options) do
    caller = self()
    context = process_context()
    receive_timeout = Keyword.get(options, :receive_timeout, :infinity)
    relay = spawn_link(fn -> run_relay(caller, context, req, receive_timeout) end)
    monitor = Process.monitor(relay)

    receive do
      {^relay, result, phase} ->
        Process.demonitor(monitor, [:flush])
        {relay_result(relay, result), phase}

      {:DOWN, ^monitor, :process, ^relay, reason} ->
        exit(reason)
    after
      min(Keyword.get(options, :wait, :infinity), Deadline.remaining(deadline)) ->
        timed_out? = Deadline.passed?(deadline)
        connected? = connected?(relay, req)
        Process.unlink(relay)
        stop_relay(relay, monitor)
        discard_relay_result(relay)

        cond do
          timed_out? -> {:timed_out, connected?}
          connected? -> {{:error, %Req.TransportError{reason: :timeout}}, :maybe_sent}
          true -> {{:error, %Req.TransportError{reason: :timeout}}, :not_sent}
        end
    end
  end

  # Finch reports the steps of the request from a process that it starts as a
  # child of the relay, which it does in an HTTP/1 pool.
  defp connected?(relay, req), do: RequestPhase.connected?(relay, finch_bounds_each_wait?(req))

  # Connecting counts toward the stall timeout, so a connection that the
  # server does not accept times out at the same moment as the wait for the
  # response headers. The wait gives the relay a little longer, so that the
  # relay can tell that the request was not sent.
  defp relay_wait(:infinity), do: :infinity
  defp relay_wait(timeout), do: timeout + min(250, div(timeout, 4))

  defp relay_result(relay, {:ok, response}) do
    {:ok, Req.Response.put_private(response, :relay, relay)}
  end

  defp relay_result(_relay, {:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp relay_result(_relay, result), do: result

  # Once the relay is down, every message it forwarded is in the mailbox.
  defp stop_relay(relay, monitor) do
    Process.exit(relay, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^relay, _reason} -> :ok
    end
  end

  # The relay may have sent its result just before it was stopped.
  defp discard_relay_result(relay) do
    receive do
      {^relay, {:ok, response}, _phase} -> Req.cancel_async_response(response)
      {^relay, _result, _phase} -> :ok
    after
      0 -> :ok
    end
  end

  # The relay tells the caller whether the request was sent at all, as Finch
  # reports it from the process that it starts for the request, whose parent
  # is the relay (see EventSourcingDB.Transport.RequestPhase).
  defp run_relay(caller, context, req, receive_timeout) do
    take_over_process_context(context)
    monitor = Process.monitor(caller)

    {result, phase} =
      RequestPhase.track_child(fn ->
        try do
          Req.request(req, into: :self, receive_timeout: receive_timeout)
        rescue
          # Finch raises rather than returns that an HTTP/2 pool has no
          # connection for a stream, which Req returns as an error for a
          # request with a single answer.
          error in Finch.Error -> {:error, %Req.HTTPError{protocol: :http2, reason: error.reason}}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end
      end)

    # From here on, the monitor watches the caller, and the link would only
    # leave an exit message for a caller that traps exits.
    Process.unlink(caller)
    send(caller, {self(), result, phase})

    case result do
      {:ok, %Req.Response{body: %Req.Response.Async{}} = response} ->
        forward(caller, monitor, response)

      _other ->
        :ok
    end
  end

  # The relay takes over what the steps of a request may take from the
  # process they run in: the callers, as a task does, so that what the caller
  # is allowed, such as the stubs of Req.Test, holds for the relay as well, the
  # Logger metadata, and the OpenTelemetry context, if OpenTelemetry is loaded,
  # so that the relay logs and traces the request as the caller would have.
  defp process_context() do
    %{
      callers: [self() | Process.get(:"$callers", [])],
      logger_metadata: Logger.metadata(),
      otel_context:
        if(function_exported?(:otel_ctx, :get_current, 0), do: :otel_ctx.get_current())
    }
  end

  defp take_over_process_context(context) do
    Process.put(:"$callers", context.callers)
    Logger.metadata(context.logger_metadata)

    if context.otel_context != nil do
      :otel_ctx.attach(context.otel_context)
    end
  end

  # Forwards the messages of the response to the caller until the response
  # ends, or until the caller is down. A caller that is down can not close the
  # response anymore, so the relay cancels it, which ends the request and
  # closes its connection, rather than leave Finch waiting for data without a
  # bound.
  defp forward(caller, monitor, %Req.Response{body: %Req.Response.Async{ref: ref}} = response) do
    receive do
      {^ref, :done} = message ->
        send(caller, message)

      {^ref, {:error, _reason}} = message ->
        send(caller, message)

      {^ref, _} = message ->
        send(caller, message)
        forward(caller, monitor, response)

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        Req.cancel_async_response(response)
        exit(:shutdown)
    end
  end

  #
  # region Request builder
  #

  # Builds the request from the options of the client, which come after those
  # of the client SDK, so that they take precedence, and the given options,
  # which come last, since the request needs them.
  #
  # With the option authorize: false, the request carries no API token, which
  # the client SDK sends only where it is needed: with every request but the
  # pings, which EventSourcingDB answers without one.
  #
  # Every request makes a single attempt, so that a request that stalls fails
  # once the stall timeout has passed, rather than after the stall timeout of
  # each attempt that Req makes by default for a GET request, such as a ping.
  # In the relay, the wait for the response headers would span every attempt
  # as well, so that attempts that failed for another reason would end as a
  # stall. A client that wants Req to retry passes Req's retry option in its
  # req_options, which take precedence.
  @spec build_request(Client.t(), atom(), String.t(), term(), keyword()) :: Req.Request.t()
  def build_request(client, method, path, body, options) do
    {authorize?, options} = Keyword.pop(options, :authorize, true)

    [
      base_url: client.base_url,
      method: method,
      url: path,
      retry: false
    ]
    |> Keyword.merge(auth_options(client, authorize?))
    |> Keyword.merge(body_options(body))
    |> Keyword.merge(client.req_options)
    |> Keyword.merge(options)
    |> put_connect_timeout(client.stall_timeout)
    |> Req.new()
  end

  defp auth_options(client, true), do: [auth: {:bearer, client.api_token}]
  defp auth_options(_client, false), do: []

  # A request without a body sends none, which a GET request must not carry
  # anyway, since Req would otherwise send it as a POST request.
  defp body_options(nil), do: []

  defp body_options(body) do
    [headers: [{"Content-Type", "application/json"}], json: body]
  end

  # Connecting counts toward a stall timeout that the client sets, so it bounds
  # connecting as well, unless the client sets a connect timeout of its own.
  # Without a stall timeout, Req's connect timeout stays. A pool that the
  # client configures through the :finch option, which Req does not take
  # together with connect options, connects as its own options say. Where the
  # client SDK waits for the response headers itself, though, that wait
  # includes connecting, so the stall timeout bounds connecting there as
  # well: for a stream with heartbeats, and for every request in a pool whose
  # waits Finch does not bound one by one, such as one that the client brings
  # by name (see request_through_relay/3).
  defp put_connect_timeout(opts, stall_timeout) do
    if stall_timeout == nil or Keyword.has_key?(opts, :finch) do
      opts
    else
      Keyword.update(
        opts,
        :connect_options,
        [timeout: stall_timeout],
        &Keyword.put_new(&1, :timeout, stall_timeout)
      )
    end
  end

  #
  # region Response validation
  #

  @spec validate_server_header(Req.Response.t()) :: :ok | {:error, InvalidServerHeader.t()}
  def validate_server_header(response) do
    if response
       |> Req.Response.get_header("Server")
       |> Enum.any?(fn val -> String.starts_with?(val, "EventSourcingDB/") end) do
      :ok
    else
      {:error, %InvalidServerHeader{}}
    end
  end
end
