import Config

config :bds, BDS.Repo,
  pool_size: 5,
  stacktrace: false,
  show_sensitive_data_on_connection_error: false

config :logger, level: :info
