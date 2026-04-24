import Config

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_prod.db", __DIR__),
  pool_size: 5,
  stacktrace: false,
  show_sensitive_data_on_connection_error: false

config :logger, level: :info