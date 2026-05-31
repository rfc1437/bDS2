import Config

config :bds,
  ecto_repos: [BDS.Repo]

config :bds, BDS.Repo,
  database:
    System.get_env("BDS_DATABASE_PATH") ||
      Path.expand("~/Library/Application Support/BDS2/bds_dev.db"),
  pool_size: 5,
  journal_mode: :wal,
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

config :bds, :ai_secret_key,
  "bds_desktop_shell_secret_key_base_64_chars_minimum_seed_value_001"

config :bds, BDS.Desktop.Endpoint,
  url: [host: "127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: BDS.Desktop.ErrorHTML], layout: false],
  pubsub_server: BDS.PubSub,
  live_view: [signing_salt: "desktop-live-view"]

config :tailwind,
  version: "4.1.14",
  default: [
    cd: Path.expand("..", __DIR__),
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    )
  ]

config :esbuild,
  version: "0.25.4",
  default: [
    cd: Path.expand("../assets", __DIR__),
    args: ~w(
      js/app.js
      --bundle
      --target=es2022
      --outdir=../priv/static/assets
      --external:/fonts/*
      --external:/images/*
    ),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :bds, :scripting,
  runtime: BDS.Scripting.Lua,
  timeout: 300_000,
  max_reductions: 5_000_000,
  job_timeout: :infinity,
  job_max_reductions: :none,
  transform_max_toasts_per_script: 5,
  transform_max_toasts_total: 20,
  transform_max_toast_length: 300

config :bds, :chat, max_tool_rounds: 10

config :bds, :embeddings,
  backend: BDS.Embeddings.Backends.Neural,
  model_id: "Xenova/multilingual-e5-small",
  model_repo: "intfloat/multilingual-e5-small",
  dimensions: 384,
  # Inference is batched: batch_size texts per compiled run, truncated to
  # sequence_length tokens. Tuning these trades throughput against memory.
  batch_size: 16,
  sequence_length: 256,
  # Hardware acceleration: :auto prefers the Apple GPU (EMLX/Metal) on Apple
  # Silicon and falls back to EXLA-CPU elsewhere. Force with :emlx or :exla.
  accelerator: :auto

# Cache downloaded model files under the app data directory so they persist
# across sessions (ModelCaching invariant). Overridden at runtime in prod.
config :bumblebee, :cache_dir,
  System.get_env("BDS_MODEL_CACHE_DIR") ||
    Path.expand("~/Library/Application Support/BDS2/models")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
