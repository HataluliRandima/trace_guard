defmodule TraceGuard.MixProject do
  use Mix.Project

  @version "0.1.0-rc.1"
  @source_url "https://github.com/HataluliRandima/trace_guard"

  def project do
    [
      app: :trace_guard,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Diagnostic reports for failed Phoenix requests: the observable timeline " <>
          "(Phoenix, Ecto, opted-in Tasks and GenServer calls), redacted and exported as JSON.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {TraceGuard.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      # Optional: only for TraceGuard.Storage.SQLite (persistent reports).
      {:exqlite, "~> 0.42", optional: true},
      # Only used to exercise the real Phoenix error-handling lifecycle in tests.
      {:phoenix, "~> 1.7", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Only what a user of the package needs. Guides, tests, the demo, scripts,
  # benchmarks and local databases stay out of the tarball.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs .formatter.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/getting_started.md",
        "docs/configuration.md",
        "docs/architecture.md",
        "docs/task_propagation.md",
        "docs/genserver_propagation.md",
        "docs/storage.md",
        "docs/security.md",
        "docs/performance.md",
        "docs/compatibility.md",
        "docs/release_checklist.md",
        "docs/phase2_review.md",
        "docs/phase3_review.md",
        "docs/phase4_review.md",
        "docs/phase5_review.md"
      ],
      groups_for_extras: [
        Guides: [
          "docs/getting_started.md",
          "docs/configuration.md",
          "docs/task_propagation.md",
          "docs/genserver_propagation.md",
          "docs/storage.md"
        ],
        Reference: [
          "docs/architecture.md",
          "docs/security.md",
          "docs/performance.md",
          "docs/compatibility.md",
          "docs/release_checklist.md"
        ],
        "Development history": [
          "docs/phase2_review.md",
          "docs/phase3_review.md",
          "docs/phase4_review.md",
          "docs/phase5_review.md"
        ]
      ],
      groups_for_modules: [
        "Public API": [TraceGuard, TraceGuard.Plug, TraceGuard.Exporter.JSON],
        "Experimental: propagation and storage": [
          TraceGuard.Server,
          TraceGuard.Storage,
          TraceGuard.ReportStore,
          TraceGuard.Storage.SQLite
        ],
        "Internals (not public API)": [
          TraceGuard.Config,
          TraceGuard.Context,
          TraceGuard.DropLog,
          TraceGuard.EventCollector,
          TraceGuard.Propagation,
          TraceGuard.Propagation.Token,
          TraceGuard.Redactor,
          TraceGuard.TaskCollector,
          TraceGuard.Telemetry,
          TraceGuard.TraceBuilder
        ]
      ]
    ]
  end
end
