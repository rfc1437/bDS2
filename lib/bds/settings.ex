defmodule BDS.Settings do
  @moduledoc false

  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting

  @spec get_global_setting(String.t()) :: String.t() | nil
  def get_global_setting(key) do
    case Repo.get(Setting, key) do
      %Setting{value: value} -> value
      _other -> nil
    end
  end

  @spec put_global_setting(String.t(), term()) :: :ok | {:error, Ecto.Changeset.t()}
  def put_global_setting(key, value) do
    setting = Repo.get(Setting, key) || %Setting{}

    setting
    |> Setting.changeset(%{
      key: key,
      value: to_string(value || ""),
      updated_at: Persistence.now_ms()
    })
    |> Repo.insert_or_update()
    |> case do
      {:ok, _setting} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
