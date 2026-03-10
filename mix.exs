defmodule Eventsourcingdb.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/thenativeweb/eventsourcingdb-client-elixir"
  @homepage_url "https://www.eventsourcingdb.io/"
  @documentation_url "https://docs.eventsourcingdb.io/"

  def project do
    [
      app: :eventsourcingdb,
      version: @version,
      elixir: "~> 1.19",
      package: package(),
      aliases: aliases(),
      deps: deps(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "EventSourcingDB",
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

  defp package do
    [
      description:
        "The official Elixir client SDK for EventSourcingDB – a purpose-built database for event sourcing.",
      links: %{
        "GitHub" => @source_url,
        "Website" => @homepage_url,
        "Documentation" => @documentation_url
      },
      licenses: ["MIT"]
    ]
  end

  defp docs do
    [
      # can be changed to a module name, if you prefer
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      # logo: "path/to/logo.png",
      extras: ["README.md"],
      groups_for_modules: [
        Events: [
          Eventsourcingdb.Event,
          Eventsourcingdb.EventCandidate,
          Eventsourcingdb.EventType,
          Eventsourcingdb.ManagementEvent
        ],
        Preconditions: [
          Eventsourcingdb.IsEventQLTrue,
          Eventsourcingdb.IsSubjectOnEventId,
          Eventsourcingdb.IsSubjectPopulated,
          Eventsourcingdb.IsSubjectPristine
        ],
        "Request Options": [
          Eventsourcingdb.BoundOptions,
          Eventsourcingdb.FromLatestEventOptions,
          Eventsourcingdb.ObserveEventsOptions,
          Eventsourcingdb.ReadEventsOptions
        ],
        Testing: [
          Eventsourcingdb.TestContainer
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
      {:testcontainers, "~> 1.14.1"},
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
