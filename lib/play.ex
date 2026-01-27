defmodule Play do
  alias Eventsourcingdb.Preconditions.IsSubjectPristine
  alias Eventsourcingdb.Events.EventCandidate
  import Eventsourcingdb

  @client Eventsourcingdb.Client.new(
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
        subject: "/books/44",
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

  def read_books() do
    stream = read_events(@client, "/books")
    Enum.each(stream, fn item -> IO.inspect(item, label: "event") end)
  end
end
