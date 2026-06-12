import Config

if config_env() == :prod do
  database_path =
    System.get_env("BDS_DATABASE_PATH") ||
      Path.expand("~/Library/Application Support/BDS2/bds.db")

  File.mkdir_p!(Path.dirname(database_path))

  # Keep prod on the same modest SQLite pool as dev so WAL + busy_timeout see
  # the same concurrency behavior in both environments unless explicitly tuned.
  config :bds, BDS.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Persist downloaded embedding model files alongside the database data dir.
  config :bumblebee,
         :cache_dir,
         System.get_env("BDS_MODEL_CACHE_DIR") ||
           Path.join(Path.dirname(Path.expand(database_path)), "models")
end
