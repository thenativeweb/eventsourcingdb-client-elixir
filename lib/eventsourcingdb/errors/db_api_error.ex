defmodule EventSourcingDB.Errors.DbApiError do
  @moduledoc """
  An error that EventSourcingDB reports.

  - `:code` - The code of the error, a URL such as `https://docs.eventsourcingdb.io/errors/precondition-violated`, exactly as the server sends it, or `nil` for an error without a code. `EventSourcingDB.ErrorCode` holds the known codes.

  - `:description` - The text that describes the error.

  - `:details` - The details of the error as a map, as the v2 API sends them, or `nil` for an error without details.

  - `:status` - The HTTP status of the answer, which is `200` for an error that the server reports in the body of an answer.

  - `:retry_after` - For the status `429`, the number of seconds to wait before trying again, as the `Retry-After` header says, or `nil` if the header is missing.
  """

  defexception [:code, :description, :details, :status, :retry_after]

  @type t() :: %__MODULE__{
          code: String.t() | nil,
          description: String.t(),
          details: map() | nil,
          status: pos_integer(),
          retry_after: non_neg_integer() | nil
        }

  @impl true
  def message(%__MODULE__{} = error) do
    code = if error.code, do: ", #{error.code}", else: ""

    "DB API Error (status #{error.status}#{code}): #{String.trim_trailing(error.description || "")}"
  end

  # An answer with another status than 200, whose body is the text of the
  # error, as the v2 API and the v1 API send it.
  @doc false
  @spec from_response(Req.Response.t(), String.t(), String.t() | nil) :: t()
  def from_response(%Req.Response{status: status} = response, text, code \\ nil) do
    %__MODULE__{
      code: code,
      description: text,
      details: nil,
      status: status,
      retry_after: retry_after(response)
    }
  end

  # An error item of the v2 API, in a stream or as the single answer.
  @doc false
  @spec from_item(any(), pos_integer()) :: t()
  def from_item(%{} = data, status) do
    %__MODULE__{
      code: data["code"],
      description: data["description"],
      details: data["details"],
      status: status
    }
  end

  def from_item(data, status) do
    %__MODULE__{description: inspect(data), status: status}
  end

  defp retry_after(%Req.Response{status: 429} = response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds
    else
      _other -> nil
    end
  end

  defp retry_after(_response), do: nil
end
