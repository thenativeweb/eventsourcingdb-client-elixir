defmodule EventSourcingDB.Transport.API do
  @moduledoc false

  # The calls that every API of EventSourcingDB answers. Each API implements
  # them on its own routes, so that EventSourcingDB.Transport only has to
  # choose one of them.

  alias EventSourcingDB.{Client, Event, EventCandidate, EventType, ManagementEvent}
  alias EventSourcingDB.{ObserveEventsOptions, ReadEventsOptions}

  @type response(t) :: {:ok, t} | {:error, Exception.t()}
  @type stream_response(t) :: {:ok, Enumerable.t(t)} | {:error, Exception.t()}

  @callback ping(Client.t()) :: :ok | {:error, Exception.t()}
  @callback verify_api_token(Client.t()) :: :ok | {:error, Exception.t()}
  @callback write_events(Client.t(), [EventCandidate.t() | map()], [struct()]) ::
              response([Event.t()])
  @callback read_events(Client.t(), String.t(), ReadEventsOptions.t() | nil) ::
              stream_response(Event.t())
  @callback observe_events(Client.t(), String.t(), ObserveEventsOptions.t() | nil) ::
              stream_response(Event.t())
  @callback run_eventql_query(Client.t(), String.t()) :: stream_response(any())
  @callback register_event_schema(Client.t(), String.t(), map()) ::
              response(ManagementEvent.t())
  @callback read_subjects(Client.t(), String.t(), boolean()) :: stream_response(String.t())
  @callback read_event_type(Client.t(), String.t()) :: response(EventType.t())
  @callback read_event_types(Client.t()) :: stream_response(EventType.t())
end
