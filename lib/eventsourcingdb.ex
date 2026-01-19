defmodule Eventscourcingdb do
  @moduledoc """
  Documentation for `Eventsourcingdb`.
  """
  alias Eventscourcingdb.Requests.{VerifyApiToken, Ping, ReadEventType, WriteEvents}

  @spec build_request(Eventscourcingdb.Client.t()) :: Req.Request.t()
  defp build_request(client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"Content-Type", "application/json"}],
      auth: {:bearer, client.api_token}
    )
  end

  @spec validate_server_headers({:ok, Req.Response.t()}) ::
          {:ok} | {:error, :invalid_server_header}
  defp validate_server_headers({:ok, response}) do
    case response
         |> Req.Response.get_header("Server")
         |> Enum.any?(fn val -> String.starts_with?(val, "Eventscourcingdb/") end) do
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

  defp validate_response({:error, reason}) do
    {:error, :api_error, reason}
  end

  defp validate_payload(body, validate_func) do
    validate_func.(body)
  end

  defp one_shot(client, request_module, body \\ nil) do
    response =
      client
      |> build_request()
      |> IO.inspect(label: "request")
      |> Req.request(url: request_module.path(), method: request_module.method(), json: body)
      |> IO.inspect(label: "response")

    with {:ok, body} <- validate_response(response),
         {:ok} <- validate_server_headers(response),
         {:ok, data} <- validate_payload(body, &request_module.validate_response/1) do
      {:ok, data}
    end
  end

  def ping(client) do
    one_shot(client, Ping)
  end

  def verify_api_token(client) do
    one_shot(client, VerifyApiToken)
  end

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
end
