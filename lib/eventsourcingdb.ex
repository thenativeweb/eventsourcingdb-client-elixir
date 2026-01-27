defmodule Eventsourcingdb do
  @moduledoc """
  Documentation for `Eventsourcingdb`.
  """
  alias Eventsourcingdb.Requests.{VerifyApiToken, Ping, ReadEventType, WriteEvents, ReadEvents}

  #
  # region Public API
  #

  @doc """
  Pings the DB instance to check if it is reachable.

  ## Examples

      iex> client = %Eventsourcingdb.Client{"http://localhost:3000", "secrettoken"}
      iex> Eventsourcingdb.ping(client)
      :ok
  """
  @spec ping(Eventsourcingdb.Client.t()) :: any()
  def ping(client) do
    request_one_shot(client, Ping.new())
  end

  @doc """
  Verifies the API token by sending a request to the DB instance.

  ## Examples

      iex> client = %Eventsourcingdb.Client{"http://localhost:3000", "secrettoken"}
      iex> Eventsourcingdb.verify_api_token(client)
      :ok
  """
  @spec verify_api_token(Eventsourcingdb.Client.t()) :: any()
  def verify_api_token(client) do
    request_one_shot(client, VerifyApiToken.new())
  end

  @spec read_event_type(Eventsourcingdb.Client.t(), any()) :: any()
  def read_event_type(client, event_type) do
    request_one_shot(client, ReadEventType.new(event_type))
  end

  @spec write_event(Eventsourcingdb.Client.t(), Eventsourcingdb.Events.EventCandidate.t()) ::
          any()
  def write_event(client, event, preconditions \\ []) do
    write_events(client, [event], preconditions)
  end

  @spec write_events(Eventsourcingdb.Client.t(), maybe_improper_list(), any()) :: any()
  def write_events(client, events, preconditions \\ []) when is_list(events) do
    request_one_shot(client, WriteEvents.new(events, preconditions))
  end

  def read_events(client, subject) do
    request_stream(client, ReadEvents.new(subject))
  end

  #
  # region Requests
  #

  defp request_stream(client, request_module) do
    Stream.resource(
      fn ->
        response =
          client
          |> build_request(request_module)
          |> Req.request(into: :self)

        with {:ok} <- validate_transmission(response),
             {:ok} <- validate_server_headers(response),
             {:ok, resp} <- validate_response(response) do
          resp
        end
      end,
      fn
        response ->
          case Req.parse_message(
                 response,
                 receive do
                   message -> message
                 end
               ) do
            {:ok, [data: chunk]} ->
              {[Jason.decode!(chunk)], response}

            # This is returned when the stream is done.
            {:ok, [:done]} ->
              {:halt, response}

            # This is received inside Finch from a process that is not the socket.
            # Ideally Req should be able to handle this and return a proper error or ignore it.
            :unknown ->
              {[], response}

            _something_else ->
              {[], response}
          end
      end,
      fn
        %Req.Response{} = resp ->
          Req.cancel_async_response(resp)

        other ->
          other
      end
    )
  end

  @spec request_one_shot(Eventsourcingdb.Client.t(), struct()) :: any()
  defp request_one_shot(client, request) do
    request_module = get_request_module(request)

    response =
      client
      |> build_request(request)
      |> Req.request()

    result =
      with {:ok} <- validate_transmission(response),
           {:ok} <- validate_server_headers(response),
           {:ok} <- validate_request_response(response, request_module),
           {:ok, resp} <- validate_response(response),
           {:ok, data} <- validate_request_body(resp.body, request_module) do
        {:ok, data}
      end

    case result do
      {:ok, nil} -> :ok
      _ -> result
    end
  end

  #
  # region Request Builder
  #

  @spec build_request(Eventsourcingdb.Client.t(), struct()) :: Req.Request.t()
  defp build_request(client, request) do
    request_module = get_request_module(request)

    opts =
      [
        base_url: client.base_url,
        auth: {:bearer, client.api_token},
        method: request_module.method(),
        url: request_module.path()
      ]
      |> Keyword.merge(build_body_opts(request))
      |> Keyword.merge(optional_fields_keyword(client))

    Req.new(opts)
    # |> Req.Request.append_request_steps(inspect: &IO.inspect/1)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_struct(mod) do
    implements_protocol?(protocol, mod.__struct__)
  end

  defp implements_protocol?(protocol, mod) when is_atom(protocol) and is_atom(mod) do
    protocol.impl_for(mod) != nil
  end

  defp build_body_opts(request_module) do
    if implements_protocol?(Jason.Encoder, request_module) do
      [
        headers: [{"Content-Type", "application/json"}],
        json: request_module
      ]
    else
      []
    end
  end

  defp optional_fields_keyword(struct) when is_map(struct) do
    # this is stupid, as it is copied from client - hmm?
    enforced = [:api_token, :base_url]

    struct
    |> Map.from_struct()
    |> Enum.reject(fn {k, _v} -> k in enforced end)
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Enum.into([])
  end

  #
  # region Response Validation
  #

  defp validate_transmission({:error, reason}) do
    {:error, :transmission_error, reason}
  end

  defp validate_transmission({:ok, _}), do: {:ok}

  @spec validate_server_headers({:ok, Req.Response.t()}) ::
          {:ok} | {:error, :invalid_server_header}
  defp validate_server_headers({:ok, response}) do
    case response
         |> Req.Response.get_header("Server")
         |> Enum.any?(fn val -> String.starts_with?(val, "EventSourcingDB/") end) do
      true -> {:ok}
      false -> {:error, :invalid_server_header}
    end
  end

  defp validate_response({:ok, %{status: 200} = response}) do
    {:ok, response}
  end

  defp validate_response({:ok, %{body: body}}) do
    {:error, :api_error, body}
  end

  defp validate_request_response(response, request_module) do
    result = request_module.validate_response(response)

    case result do
      :ok -> {:ok, nil}
      _ -> result
    end
  end

  defp validate_request_body(body, request_module) do
    result = request_module.validate_body(body)

    case result do
      :ok -> {:ok, nil}
      _ -> result
    end
  end

  defp get_request_module(struct) when is_struct(struct) do
    struct.__struct__
  end

  defp get_request_module(module) do
    module
  end
end
