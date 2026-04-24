import Config

if config_env() == :prod do
  database_path =
    System.get_env("BDS_DATABASE_PATH") ||
      Path.expand("../priv/data/bds_prod.db", __DIR__)

  config :bds, BDS.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1")
end
