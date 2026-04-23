import Config

config :bds,
  ecto_repos: [BDS.Repo]

config :bds, BDS.Repo,
  database: Path.expand("../priv/data/bds_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :bds, BDS.Application,
  desktop_adapter: :pending_selection

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
