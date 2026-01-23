defmodule Eventscourcingdb do
  @moduledoc """
  Documentation for `Eventsourcingdb`.
  """
  alias Eventscourcingdb.Requests.{VerifyApiToken, Ping, ReadEventType, WriteEvents}

  @doc """
  Pings the DB instance to check if it is reachable.

  ## Examples

      iex> client = %Eventscourcingdb.Client{"http://localhost:3000", "secrettoken"}
      iex> Eventsourcingdb.ping(client)
      :ok
  """
  @spec ping(Eventscourcingdb.Client.t()) :: any()
  def ping(client) do
    one_shot(client, Ping)
  end

  @doc """
  Verifies the API token by sending a request to the DB instance.

  ## Examples

      iex> client = %Eventscourcingdb.Client{"http://localhost:3000", "secrettoken"}
      iex> Eventsourcingdb.verify_api_token(client)
      :ok
  """
  @spec verify_api_token(Eventscourcingdb.Client.t()) :: any()
  def verify_api_token(client) do
    one_shot(client, VerifyApiToken)
  end

  @spec read_event_type(Eventscourcingdb.Client.t(), any()) :: any()
  def read_event_type(client, event_type) do
    one_shot(client, ReadEventType, %{"eventType" => event_type})
  end

  @spec write_event(Eventscourcingdb.Client.t(), Eventscourcingdb.Events.EventCandidate.t()) ::
          any()
  def write_event(client, event, preconditions \\ []) do
    write_events(client, [event], preconditions)
  end

  @spec write_events(Eventscourcingdb.Client.t(), maybe_improper_list(), any()) :: any()
  def write_events(client, events, preconditions \\ []) when is_list(events) do
    one_shot(client, WriteEvents, %{"events" => events, "preconditions" => preconditions})
  end

  # private

  defp one_shot(client, request_module, body \\ nil) do
    response =
      client
      |> build_request()
      # |> IO.inspect(label: "request")
      |> Req.request(url: request_module.path(), method: request_module.method(), json: body)

    # |> IO.inspect(label: "response")

    result =
      with {:ok} <- validate_transmission(response),
           {:ok} <- validate_server_headers(response),
           {:ok} <- validate_request_response(response, request_module),
           {:ok, body} <- validate_response(response),
           {:ok, data} <- validate_request_body(body, request_module) do
        {:ok, data}
      end

    case result do
      {:ok, nil} -> :ok
      _ -> result
    end
  end

  @spec build_request(Eventscourcingdb.Client.t()) :: Req.Request.t()
  defp build_request(client) do
    base_opts = [
      base_url: client.base_url,
      headers: [{"Content-Type", "application/json"}],
      auth: {:bearer, client.api_token}
    ]

    opts = Keyword.merge(base_opts, optional_fields_keyword(client))

    Req.new(opts)
  end

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

  defp validate_response({:ok, %{status: 200, body: body}}) do
    {:ok, body}
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

  defp optional_fields_keyword(struct) when is_map(struct) do
    # this is stupid, as it is copied from client - hmm?
    enforced = [:api_token, :base_url]

    struct
    |> Map.from_struct()
    |> Enum.reject(fn {k, _v} -> k in enforced end)
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Enum.into([])
  end
end
