defmodule BDS.MixProject do
  use Mix.Project

  def project do
    [
      app: :bds,
      version: "0.1.0",
      elixir: "~> 1.17",
      default_release: :bds,
      releases: releases(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx],
      mod: {BDS.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.21"},
      {:luerl, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:earmark, "~> 1.4"},
      {:liquex, "~> 0.13.1"},
      {:plug, "~> 1.18"},
      {:bandit, "~> 1.5"},
      {:desktop, "~> 1.5"},
      {:image, "~> 0.65"},
      {:stemex, "~> 0.2.1"}
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

  defp releases do
    [
      bds: [
        include_executables_for: [:unix, :windows],
        applications: [bds: :permanent]
      ],
      bds_mcp: [
        path: "_build/#{Mix.env()}/rel/bds_mcp",
        include_executables_for: [:unix, :windows],
        applications: [bds: :permanent]
      ]
    ]
  end
end
