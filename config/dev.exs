import Config

config :bds, BDS.Repo, pool_size: 5

config :bds, BDS.Desktop.Endpoint,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]},
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--watch)]}
  ]
