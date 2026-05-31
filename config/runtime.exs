import Config

if config_env() == :prod do
  database_path =
    System.get_env("BDS_DATABASE_PATH") ||
      Path.expand("~/Library/Application Support/BDS2/bds.db")

  File.mkdir_p!(Path.dirname(database_path))

  config :bds, BDS.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1")

  # Persist downloaded embedding model files alongside the database data dir.
  config :bumblebee,
         :cache_dir,
         System.get_env("BDS_MODEL_CACHE_DIR") ||
           Path.join(Path.dirname(Path.expand(database_path)), "models")
end
