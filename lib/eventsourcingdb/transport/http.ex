defmodule EventSourcingDB.Transport.HTTP do
  @moduledoc false

  # The HTTP machinery that every API shares: building a request, sending a
  # request with a single answer, and opening and reading a stream of NDJSON
  # lines, each bounded by the stall timeout of the client.

  alias EventSourcingDB.Client

  alias EventSourcingDB.Errors.{
    ApiError,
    HeartbeatTimeout,
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

  # A request with a single answer runs in the calling process. Finch bounds
  # each wait for data with the receive timeout there, and connecting with the
  # connect timeout (see build_request/5). The body is not decoded, so that
  # each API decodes it as it needs, for example events with the text of their
  # data as it arrived, for verifying their hash.
  @spec one_shot(Client.t(), atom(), String.t(), term(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def one_shot(client, method, path, body, options \\ []) do
    req = build_request(client, method, path, body, options)

    case Req.request(req, receive_timeout: receive_timeout(client, req), decode_body: false) do
      {:ok, response} ->
        with :ok <- validate_server_header(response), do: {:ok, response}

      {:error, reason} ->
        {:error, %TransmissionError{reason: reason}}
    end
  end

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
  #   * :ends? - whether the server ends the stream with an end item, which it
  #     then must not leave out
  #   * :status_error - turns an answer with another status than 200, given as
  #     the response and the text of its body, into an error
  @spec stream(Client.t(), atom(), String.t(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Exception.t()}
  def stream(client, method, path, body, options) do
    req = build_request(client, method, path, body, [])
    heartbeats? = Keyword.fetch!(options, :heartbeats?)
    status_error = Keyword.get(options, :status_error, &default_status_error/2)

    stall_timeout =
      if heartbeats?, do: heartbeat_timeout(client), else: receive_timeout(client, req)

    case open_stream(req, stall_timeout, heartbeats?, status_error) do
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
          heartbeats?: heartbeats?,
          decode: Keyword.fetch!(options, :decode),
          ends?: Keyword.get(options, :ends?, false),
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
  # (see finch_bounds_each_wait?/1).
  defp open_stream(req, stall_timeout, heartbeats?, status_error) do
    {response, wait} =
      if not heartbeats? and finch_bounds_each_wait?(req) do
        {Req.request(req, into: :self, receive_timeout: stall_timeout), :infinity}
      else
        {request_through_relay(req, stall_timeout), stall_timeout}
      end

    case response do
      {:ok, response} ->
        validate_stream_response(response, wait, status_error)

      {:error, reason} ->
        {:error, %TransmissionError{reason: reason}}
    end
    |> case do
      {:ok, response} -> {:ok, response, wait}
      error -> error
    end
  end

  # A stream that fails to open closes its response right away, so that none
  # of its messages stay behind in the mailbox.
  defp validate_stream_response(response, wait, status_error) do
    with :ok <- validate_server_header(response),
         :ok <- validate_stream_status(response, wait, status_error) do
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
  defp validate_stream_status(%Req.Response{status: 200}, _wait, _status_error), do: :ok

  defp validate_stream_status(response, wait, status_error) do
    case read_body(response, wait, "") do
      {:ok, text} -> {:error, status_error.(response, text)}
      {:error, reason} -> {:error, %TransmissionError{reason: reason}}
    end
  end

  defp default_status_error(_response, text), do: %ApiError{reason: text}

  # Reads the rest of the body, and waits for each block of it at most for the
  # timeout, unless Finch bounds the wait.
  defp read_body(response, wait, body) do
    case receive_message(response, deadline(wait)) do
      {:ok, [data: data]} -> read_body(response, wait, body <> data)
      {:ok, [:done]} -> {:ok, body}
      {:ok, _other} -> read_body(response, wait, body)
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, %Req.TransportError{reason: :timeout}}
    end
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
  defp receive_items(%{status: :ended} = state), do: {:halt, state}
  defp receive_items(%{status: {:failed, reason}}), do: raise(reason)

  defp receive_items(state) do
    case receive_message(state.response, deadline(state.wait)) do
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
        raise(%TransmissionError{reason: reason})

      :timeout ->
        raise(timeout_error(state))
    end
  end

  # A stream whose server ends it with an end item fails if the response ends
  # before that item, since the server then broke it off.
  defp finish(%{status: :open, ends?: true} = state) do
    %{state | status: {:failed, incomplete_stream_error()}}
  end

  defp finish(%{status: :open} = state), do: %{state | status: :ended}
  defp finish(state), do: state

  @doc false
  @spec incomplete_stream_error() :: Exception.t()
  def incomplete_stream_error() do
    %TransmissionError{reason: %RuntimeError{message: "the stream ended without its end item"}}
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

  defp timeout_error(%{heartbeats?: true, stall_timeout: stall_timeout}) do
    %HeartbeatTimeout{
      message:
        "Heartbeat Timeout: No event and no heartbeat arrived for #{duration(stall_timeout)}."
    }
  end

  defp timeout_error(_state) do
    %TransmissionError{reason: %Req.TransportError{reason: :timeout}}
  end

  defp duration(1_000), do: "1 second"

  defp duration(milliseconds) when rem(milliseconds, 1_000) == 0,
    do: "#{div(milliseconds, 1_000)} seconds"

  defp duration(1), do: "1 millisecond"
  defp duration(milliseconds), do: "#{milliseconds} milliseconds"

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
  # brings by name are unknown, so the stream bounds each wait itself there,
  # whether the pool speaks HTTP/1 or HTTP/2.
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
  # than each wait for data, so a stream that runs for longer would end while
  # data still arrives, and in an HTTP/1 pool, the receive timeout would end a
  # stream with heartbeats with an error of its own. So such a stream asks
  # Finch for no timeout, and bounds each wait itself: the wait for the
  # response headers here, from sending the request, and the wait for each
  # block of the response in receive_items/1. Req then waits for the response
  # headers in a receive without any bound, which the caller can not
  # interrupt, so the request runs in a relay process, which forwards the
  # messages of the response to the caller, while the caller bounds the wait.
  # A pool that the client brings by name takes this path as well, even one
  # that speaks HTTP/1, where Finch then waits for data without a bound, too.
  #
  # The relay is linked to the caller while it waits for the response headers,
  # and monitors it afterwards, so it does not outlive the caller. Finch in turn
  # cancels the request once the relay is down.
  defp request_through_relay(req, timeout) do
    caller = self()
    context = process_context()
    relay = spawn_link(fn -> run_relay(caller, context, req) end)
    monitor = Process.monitor(relay)

    receive do
      {^relay, result} ->
        Process.demonitor(monitor, [:flush])
        relay_result(relay, result)

      {:DOWN, ^monitor, :process, ^relay, reason} ->
        exit(reason)
    after
      timeout ->
        Process.unlink(relay)
        stop_relay(relay, monitor)
        discard_relay_result(relay)
        {:error, %Req.TransportError{reason: :timeout}}
    end
  end

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
      {^relay, {:ok, response}} -> Req.cancel_async_response(response)
      {^relay, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp run_relay(caller, context, req) do
    take_over_process_context(context)
    monitor = Process.monitor(caller)

    result =
      try do
        Req.request(req, into: :self, receive_timeout: :infinity)
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    # From here on, the monitor watches the caller, and the link would only
    # leave an exit message for a caller that traps exits.
    Process.unlink(caller)
    send(caller, {self(), result})

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
  @spec build_request(Client.t(), atom(), String.t(), term(), keyword()) :: Req.Request.t()
  def build_request(client, method, path, body, options) do
    [
      base_url: client.base_url,
      auth: {:bearer, client.api_token},
      method: method,
      url: path
    ]
    |> Keyword.merge(body_options(body))
    |> Keyword.merge(client.req_options)
    |> Keyword.merge(options)
    |> put_connect_timeout(client.stall_timeout)
    |> Req.new()
  end

  # A request without a body sends none, which a GET request must not carry
  # anyway, since Req would otherwise send it as a POST request.
  defp body_options(nil), do: []

  defp body_options(body) do
    [headers: [{"Content-Type", "application/json"}], json: body]
  end

  # Connecting counts toward a stall timeout that the client sets, so it bounds
  # connecting as well, unless the client sets a connect timeout of its own.
  # Without a stall timeout, Req's connect timeout stays, and a pool that the
  # client brings by name is connected as its options say.
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
