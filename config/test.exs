import Config

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  journal_mode: :wal,
  # Desktop/LiveView tests can leave short-lived reader/writer processes
  # draining after assertions. Give SQLite more time to wait out those locks
  # during serialized suite runs instead of failing the next test setup.
  busy_timeout: 60_000

config :logger, level: :warning

# Deterministic, test-only master key so secret round-trips never touch the
# OS keyring (Keychain) or write key files on developer machines.
config :bds, :ai_secret_key, "bds-test-only-ai-secret-key-not-used-outside-the-test-env"

# Tests use the deterministic lexical stub backend so the suite stays offline
# and never downloads the ~100 MB neural model.
config :bds, :embeddings,
  backend: BDS.Embeddings.Backends.InApp,
  model_id: "Xenova/multilingual-e5-small",
  model_repo: "intfloat/multilingual-e5-small",
  dimensions: 384,
  batch_size: 16,
  sequence_length: 256
