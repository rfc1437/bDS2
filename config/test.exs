import Config

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  journal_mode: :wal,
  busy_timeout: 15_000

config :logger, level: :warning

# Tests use the deterministic lexical stub backend so the suite stays offline
# and never downloads the ~100 MB neural model.
config :bds, :embeddings,
  backend: BDS.Embeddings.Backends.InApp,
  model_id: "Xenova/multilingual-e5-small",
  model_repo: "intfloat/multilingual-e5-small",
  dimensions: 384
