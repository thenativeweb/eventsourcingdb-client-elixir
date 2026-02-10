defmodule Eventsourcingdb.MixProject do
  alias Eventsourcingdb.ObserveEventsOptions
  alias Eventsourcingdb.ReadEventsOptions
  alias Eventsourcingdb.FromLatestEventOptions
  alias Eventsourcingdb.BoundOptions
  alias Eventsourcingdb.TestContainer
  alias Eventsourcingdb.IsSubjectPristine
  alias Eventsourcingdb.IsSubjectPopulated
  alias Eventsourcingdb.IsSubjectOnEventId
  alias Eventsourcingdb.IsEventQLTrue
  alias Eventsourcingdb.ManagementEvent
  alias Eventsourcingdb.EventType
  alias Eventsourcingdb.EventCandidate
  alias Eventsourcingdb.Event
  use Mix.Project

  def project do
    [
      app: :eventsourcingdb,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "EventSourcingDB",
      source_url: "https://github.com/thenativeweb/eventsourcingdb-client-elixir",
      homepage_url: "https://eventsourcingdb.io",
      docs: &docs/0
    ]
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "test/support"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      # can be changed to a module name, if you prefer
      main: "readme",
      # logo: "path/to/logo.png",
      extras: ["README.md"],
      groups_for_modules: [
        Events: [
          Event,
          EventCandidate,
          EventType,
          ManagementEvent
        ],
        Preconditions: [
          IsEventQLTrue,
          IsSubjectOnEventId,
          IsSubjectPopulated,
          IsSubjectPristine
        ],
        "Request Options": [
          BoundOptions,
          FromLatestEventOptions,
          ObserveEventsOptions,
          ReadEventsOptions
        ],
        Testing: [
          TestContainer
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5.16"},
      {:jason, "~> 1.2"},
      {:ex_json_schema, "~> 0.11.2"},
      {:typedstruct, "~> 0.5"},
      {:testcontainers, "~> 1.14.1", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      i: ["deps.get"],
      ic: ["deps.get", "deps.compile"]
    ]
  end
end
