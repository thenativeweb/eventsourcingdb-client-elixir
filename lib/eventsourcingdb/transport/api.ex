defmodule EventSourcingDB.Transport.API do
  @moduledoc false

  # The calls that every API of EventSourcingDB answers. Each API implements
  # them on its own routes, so that EventSourcingDB.Transport only has to
  # choose one of them. Each call takes the deadline of a call that was given
  # a timeout, or nil.

  alias EventSourcingDB.{Client, Event, EventCandidate, EventType, ManagementEvent}
  alias EventSourcingDB.{ObserveEventsOptions, ReadEventsOptions}
  alias EventSourcingDB.Transport.Deadline

  @type response(t) :: {:ok, t} | {:error, Exception.t()}
  @type stream_response(t) :: {:ok, Enumerable.t(t)} | {:error, Exception.t()}
  @type deadline() :: Deadline.t() | nil

  @callback ping(Client.t(), deadline()) :: :ok | {:error, Exception.t()}
  @callback verify_api_token(Client.t(), deadline()) :: :ok | {:error, Exception.t()}
  @callback write_events(Client.t(), [EventCandidate.t() | map()], [struct()], deadline()) ::
              response([Event.t()])
  @callback read_events(Client.t(), String.t(), ReadEventsOptions.t() | nil, deadline()) ::
              stream_response(Event.t())
  @callback observe_events(Client.t(), String.t(), ObserveEventsOptions.t() | nil, deadline()) ::
              stream_response(Event.t())
  @callback run_eventql_query(Client.t(), String.t(), deadline()) :: stream_response(any())
  @callback register_event_schema(Client.t(), String.t(), map(), deadline()) ::
              response(ManagementEvent.t())
  @callback read_subjects(Client.t(), String.t(), boolean(), deadline()) ::
              stream_response(String.t())
  @callback read_event_type(Client.t(), String.t(), deadline()) :: response(EventType.t())
  @callback read_event_types(Client.t(), deadline()) :: stream_response(EventType.t())
end
