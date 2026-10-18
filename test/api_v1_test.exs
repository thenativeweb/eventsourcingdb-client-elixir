defmodule EventSourcingDBTest.ApiV1 do
  alias EventSourcingDB.ReadSubjectsOptions
  alias EventSourcingDBTest.StreamServer
  use ExUnit.Case, async: true

  # The behavior of the client SDK that only servers without the v2 API show.

  describe "reading subjects" do
    test "reads recursively from the subject, and keeps the subject alone if it does not read recursively" do
      client = serve_subjects(["/books", "/books/42", "/books/42/pages", "/books/43"])

      {result, _elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_subjects!(client, "/books", %ReadSubjectsOptions{recursive: false})
          |> Enum.to_list()
        end)

      assert result == {:ok, ["/books"]}
      assert_receive {:stream_server, :request, "POST /api/v1/read-subjects HTTP/1.1", body}
      assert Jason.decode!(body) == %{"baseSubject" => "/books"}
    end

    test "keeps every subject if it reads recursively" do
      subjects = ["/books", "/books/42", "/books/42/pages", "/books/43"]
      client = serve_subjects(subjects)

      {result, _elapsed} =
        StreamServer.run_with_guard(fn ->
          EventSourcingDB.read_subjects!(client, "/books", %ReadSubjectsOptions{recursive: true})
          |> Enum.to_list()
        end)

      assert result == {:ok, subjects}
      assert_receive {:stream_server, :request, "POST /api/v1/read-subjects HTTP/1.1", body}
      assert Jason.decode!(body) == %{"baseSubject" => "/books"}
    end
  end

  defp serve_subjects(subjects) do
    StreamServer.start(fn socket ->
      StreamServer.send_head(socket)

      for subject <- subjects do
        StreamServer.send_line(socket, %{
          "type" => "subject",
          "payload" => %{"subject" => subject}
        })
      end

      StreamServer.send_end(socket)
    end)
  end
end
