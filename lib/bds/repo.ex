defmodule BDS.Repo do
  use Ecto.Repo,
    otp_app: :bds,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Returns true if the database is connected and core tables exist.
  Used to guard data access during startup before migrations have run.
  """
  def ready? do
    case Ecto.Adapters.SQL.query(
           __MODULE__,
           "SELECT 1 FROM sqlite_master WHERE type = ?1 AND name = ?2 LIMIT 1",
           ["table", "projects"]
         ) do
      {:ok, %{num_rows: 1}} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  rescue
    _ -> false
  end
end
