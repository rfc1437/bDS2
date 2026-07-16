import Config

# Headless boots (BDS_MODE=server/tui, or desktop mode without a graphical
# display — issue #33) must neuter wx before the :desktop dependency
# application starts it and crashes the VM. Local tui mode additionally
# silences all other terminal writers (console logging goes to a file,
# model-download progress bars are disabled) — the TUI owns the terminal
# and every stray line scrolls its rendering up one row. Runtime config is
# the only hook that runs before dependency applications start.
BDS.Server.prepare_boot_env()

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
