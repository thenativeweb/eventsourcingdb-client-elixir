defmodule Eventsourcingdb.Events.ManagementEvent do
  defstruct [:data, :datacontenttype, :id, :source, :specversion, :subject, :time, :type]
end
