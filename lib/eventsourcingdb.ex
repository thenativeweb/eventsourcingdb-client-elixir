defmodule EventSourcingDB do
  @moduledoc """
  Documentation for `Eventsourcingdb`.
  """
  alias EventSourcingDB.Requests.{VerifyApiToken, Ping, ReadEventType}

  def play() do
    client =
      Eventsourcingdb.Client.new(
        api_token: "LuD3fBJCZF@q&%w4bJ&R",
        base_url: "http://localhost:3001"
      )

    ping(client) |> IO.inspect(label: "ping")
    verify_api_token(client) |> IO.inspect(label: "verify_api_token")
  end

  @spec build_request(
          Eventsourcingdb.Client.t(),
          module(),
          any()
        ) :: Req.Request.t()
  defp build_request(client, request_module, body) do
    Req.new(
      method: request_module.method(),
      url: URI.merge(client.base_url, request_module.path()),
      json: Jason,
      headers: [{"Content-Type", "application/json"}],
      auth: {:bearer, client.api_token},
      body: body
    )
  end

  defp handle_response({:ok, %{status: 200, body: body}}, validate_func) do
    validate_func.(body)
  end

  defp handle_response({:ok, %{status: status}}, _validate_func),
    do: {:error, "Unexpected status: #{status}"}

  defp handle_response({:error, reason}, _validate_func), do: {:error, reason}

  defp one_shot(client, request_module, body \\ nil) do
    client
    |> build_request(request_module, body)
    # |> IO.inspect(label: "request")
    |> Req.request()
    # |> IO.inspect(label: "response")
    |> handle_response(&request_module.validate_response/1)
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
end
