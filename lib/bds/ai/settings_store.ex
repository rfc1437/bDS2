defmodule BDS.AI.SettingsStore do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.CatalogMeta
  alias BDS.AI.SecretBackend
  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting

  @spec get_setting(String.t()) :: String.t() | nil
  def get_setting(key) do
    case Repo.get(Setting, key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @spec put_setting(String.t(), String.t()) :: :ok
  def put_setting(key, value) when is_binary(key) and is_binary(value) do
    now = Persistence.now_ms()

    (%Setting{}
     |> Setting.changeset(%{key: key, value: value, updated_at: now}))
    |> Repo.insert(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: [:key]
    )

    :ok
  end

  @spec delete_setting(String.t()) :: :ok
  def delete_setting(key) do
    Repo.delete_all(from(setting in Setting, where: setting.key == ^key))
    :ok
  end

  @spec put_secret(String.t(), String.t() | nil, module()) :: :ok | {:error, term()}
  def put_secret(_key, nil, _backend), do: :ok

  def put_secret(key, value, backend) do
    with {:ok, encrypted_value} <- backend.encrypt(value) do
      put_setting(encrypted_key(key), encrypted_value)
    end
  end

  @spec get_secret(String.t() | nil, module()) :: {:ok, String.t() | nil} | {:error, term()}
  def get_secret(nil, _backend), do: {:ok, nil}
  def get_secret(value, backend), do: backend.decrypt(value)

  @spec encrypted_key(String.t()) :: String.t()
  def encrypted_key(key), do: "__encrypted_#{key}"

  @spec secret_backend() :: module()
  def secret_backend, do: SecretBackend

  @spec get_catalog_meta_value(String.t()) :: String.t() | nil
  def get_catalog_meta_value(key) do
    case Repo.get(CatalogMeta, key) do
      nil -> get_setting("ai.catalog.#{key}")
      meta -> meta.value
    end
  end

  @spec put_catalog_meta(String.t(), String.t()) :: :ok
  def put_catalog_meta(key, value) do
    %CatalogMeta{}
    |> CatalogMeta.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: [set: [value: value]],
      conflict_target: [:key]
    )

    :ok
  end
end
