import Config

config :bds,
  ecto_repos: [BDS.Repo]

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_dev.db", __DIR__),
  pool_size: 5,
  busy_timeout: 15_000,
  log: false,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :bds, BDS.Application, desktop_adapter: :desktop

config :bds, :desktop,
  port: 4010,
  window_size: {1280, 780},
  window_min_size: {800, 600},
  title: "Blogging Desktop Server",
  secret_key_base: "bds_desktop_shell_secret_key_base_64_chars_minimum_seed_value_001"

config :bds, :scripting,
  runtime: BDS.Scripting.Lua,
  timeout: 300_000,
  max_reductions: 5_000_000,
  job_timeout: :infinity,
  job_max_reductions: :none

config :bds, :embeddings,
  backend: BDS.Embeddings.Backends.InApp,
  model_id: "Xenova/multilingual-e5-small",
  dimensions: 384

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
