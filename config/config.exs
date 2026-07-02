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

# No secrets live in this file: the endpoint signing secret is generated per
# boot (BDS.Application) and the AI secret master key comes from the OS
# keyring (BDS.AI.SecretKey).
config :bds, :desktop,
  port: 4010,
  window_size: {1280, 780},
  window_min_size: {800, 600},
  title: "Blogging Desktop Server"

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
  ],
  monaco: [
    cd: Path.expand("../assets", __DIR__),
    args: ~w(
      js/monaco_entry.js
      --bundle
      --target=es2022
      --format=esm
      --outfile=../priv/static/assets/monaco.js
      --loader:.ttf=dataurl
    ),
    env: %{"NODE_PATH" => Path.expand("../node_modules", __DIR__)}
  ],
  monaco_workers: [
    cd: Path.expand("../assets", __DIR__),
    args: ~w(
      js/monaco_workers/editor.worker.js
      js/monaco_workers/css.worker.js
      js/monaco_workers/html.worker.js
      js/monaco_workers/json.worker.js
      js/monaco_workers/ts.worker.js
      --bundle
      --target=es2022
      --format=esm
      --outdir=../priv/static/assets/monaco
      --loader:.ttf=dataurl
    ),
    env: %{"NODE_PATH" => Path.expand("../node_modules", __DIR__)}
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

# streaming: chat completions use SSE when the provider supports it (set to
# false for OpenAI-compatible servers that reject the "stream" flag).
# stream_emit_interval_ms throttles how often streamed content reaches the UI.
# await_timeout_margin_ms is added on top of the per-request HTTP budget across
# the bounded tool-call loop, so the caller never waits forever.
config :bds, :chat,
  max_tool_rounds: 10,
  streaming: true,
  stream_emit_interval_ms: 100,
  await_timeout_margin_ms: 5_000

config :bds, :git,
  local_timeout_ms: 15_000,
  network_timeout_ms: 120_000

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
