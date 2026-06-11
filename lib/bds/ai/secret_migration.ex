defmodule BDS.AI.SecretMigration do
  @moduledoc """
  Idempotent boot-time re-encryption of stored AI secrets.

  Earlier releases encrypted secrets with key material shipped in the
  repository (or a deterministic node-name fallback). This pass finds the
  `__encrypted_*` rows in `settings`, decrypts them with the legacy keys, and
  re-encrypts them with the machine-local key from `BDS.AI.SecretKey`. Rows
  already encrypted with the current key are left untouched; rows no known
  key can decrypt are left in place and reported, so the user can re-enter
  the secret. Runs from `BDS.RepoBootstrap` on every boot; on a migrated
  database it is a cheap no-op.
  """

  import Ecto.Query

  require Logger

  alias BDS.AI.SecretBackend
  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting

  @encrypted_prefix "__encrypted_"

  @spec migrate_legacy_secrets(module()) ::
          {:ok, %{migrated: non_neg_integer(), failed: non_neg_integer()}}
  def migrate_legacy_secrets(repo \\ Repo) do
    summary =
      from(setting in Setting, where: like(setting.key, ^"#{@encrypted_prefix}%"))
      |> repo.all()
      |> Enum.reduce(%{migrated: 0, failed: 0}, fn setting, acc ->
        case migrate_row(repo, setting) do
          :current -> acc
          :migrated -> %{acc | migrated: acc.migrated + 1}
          :failed -> %{acc | failed: acc.failed + 1}
        end
      end)

    {:ok, summary}
  end

  defp migrate_row(repo, setting) do
    with {:error, _no_current_key_match} <- SecretBackend.decrypt_with_current_key(setting.value),
         {:ok, plaintext} <- SecretBackend.decrypt_legacy(setting.value),
         {:ok, reencrypted} <- SecretBackend.encrypt(plaintext) do
      repo.update_all(
        from(s in Setting, where: s.key == ^setting.key),
        set: [value: reencrypted, updated_at: Persistence.now_ms()]
      )

      Logger.info("AI secret #{setting.key} re-encrypted with the machine-local key")
      :migrated
    else
      {:ok, _already_current} ->
        :current

      {:error, reason} ->
        Logger.warning(
          "AI secret #{setting.key} could not be re-encrypted (#{inspect(reason)}); " <>
            "leaving it unchanged — the secret may need to be entered again"
        )

        :failed
    end
  end
end
