defmodule BDS.Repo do
  use Ecto.Repo,
    otp_app: :bds,
    adapter: Ecto.Adapters.SQLite3
end
