defmodule TraceGuard.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :trace_guard,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Reconstructs the observable timeline of failed Phoenix requests " <>
          "and exports a redacted JSON diagnostic report.",
      package: [licenses: ["Apache-2.0"]],
      docs: [main: "readme", extras: ["README.md" | Path.wildcard("docs/*.md")]]
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
      # Only used to exercise the real Phoenix error-handling lifecycle in tests.
      {:phoenix, "~> 1.7", only: :test}
    ]
  end
end
