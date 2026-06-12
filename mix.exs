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
      dialyzer: dialyzer(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx, :ssl],
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
      {:req, "~> 0.5"},
      {:saxy, "~> 1.4"},
      {:desktop, "~> 1.5"},
      {:image, "~> 0.67"},
      {:nx, "~> 0.10"},
      {:exla, "~> 0.10"},
      # Apple Silicon GPU (Metal) acceleration for embedding inference. Ships
      # precompiled MLX binaries; the Neural backend prefers it on arm64 macOS
      # and falls back to EXLA-CPU elsewhere (SPECGAPS A1-14c).
      {:emlx, "~> 0.2.0"},
      {:bumblebee, "~> 0.6.3"},
      {:hnswlib, "~> 0.1.7"},
      {:stemex, "~> 0.2.1"},
      {:gettext, "~> 0.24"},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind default", "esbuild default"],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      validate: ["test", "dialyzer"]
    ]
  end

  defp dialyzer do
    env = Mix.env()

    [
      plt_add_apps: [:mix, :inets, :ssl, :nx, :exla, :emlx, :bumblebee, :hnswlib],
      paths: ["_build/#{env}/lib/bds/ebin"]
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
