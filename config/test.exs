import Config

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :logger, level: :warning