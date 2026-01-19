defmodule Play do
  alias Eventscourcingdb.Preconditions.IsSubjectPristine
  alias Eventscourcingdb.Events.EventCandidate
  import Eventscourcingdb

  @client Eventscourcingdb.Client.new(
            api_token: "LuD3fBJCZF@q&%w4bJ&R",
            base_url: "http://localhost:3001"
          )

  @spec status() :: none()
  def status() do
    ping(@client) |> IO.inspect(label: "ping")
    verify_api_token(@client) |> IO.inspect(label: "verify_api_token")
  end

  @spec write_book() :: none()
  def write_book() do
    write_event(
      @client,
      %EventCandidate{
        type: "io.eventsourcingdb.library.book-acquired",
        subject: "/books/43",
        source: "https://library.eventsourcingdb.io",
        data: %{
          title: "2001 – A Space Odyssey",
          author: "Arthur C. Clarke",
          isbn: "978-0756906788"
        }
      },
      [%IsSubjectPristine{subject: "/books/43"}]
    )
  end
end
