defmodule Cranium.MixProject do
  use Mix.Project

  def project do
    [
      app: :cranium,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Cranium.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},

      # HTTP client
      {:req, "~> 0.5"},

      # HTTP server
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # JSON
      {:jason, "~> 1.4"},

      # Telemetry
      {:telemetry, "~> 1.3"},

      # Static analysis
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:typed_struct, "~> 0.3"},
      {:typed_ecto_schema, "~> 0.4"},

      # Test
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
