defmodule BDS.AI.SecretMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BDS.AI.SecretBackend
  alias BDS.AI.SecretMigration
  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting

  # Key material shipped in the repository before TD-01; used to seed rows the
  # way earlier releases stored them.
  @legacy_repo_key binary_part(
                     "bds_desktop_shell_secret_key_base_64_chars_minimum_seed_value_001",
                     0,
                     32
                   )

  @aad "bds-ai-secret"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok
  end

  defp encrypt_with(key, value) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)
    Base.encode64(iv <> tag <> ciphertext)
  end

  defp insert_setting(key, value) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: value, updated_at: Persistence.now_ms()})
    |> Repo.insert!()
  end

  test "re-encrypts secrets stored with the legacy repo key" do
    legacy_value = encrypt_with(@legacy_repo_key, "sk-online-123")
    insert_setting("__encrypted_ai.online.api_key", legacy_value)

    assert {:ok, %{migrated: 1, failed: 0}} = SecretMigration.migrate_legacy_secrets()

    %Setting{value: new_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
    refute new_value == legacy_value
    assert {:ok, "sk-online-123"} = SecretBackend.decrypt_with_current_key(new_value)
  end

  test "re-encrypts secrets stored with the legacy node-name key" do
    node_key = :crypto.hash(:sha256, Atom.to_string(node()) <> ":bds:ai")
    legacy_value = encrypt_with(node_key, "sk-airplane-456")
    insert_setting("__encrypted_ai.airplane.api_key", legacy_value)

    assert {:ok, %{migrated: 1, failed: 0}} = SecretMigration.migrate_legacy_secrets()

    %Setting{value: new_value} = Repo.get(Setting, "__encrypted_ai.airplane.api_key")
    assert {:ok, "sk-airplane-456"} = SecretBackend.decrypt_with_current_key(new_value)
  end

  test "leaves rows already encrypted with the current key untouched" do
    {:ok, current_value} = SecretBackend.encrypt("sk-current-789")
    insert_setting("__encrypted_ai.online.api_key", current_value)

    assert {:ok, %{migrated: 0, failed: 0}} = SecretMigration.migrate_legacy_secrets()

    assert %Setting{value: ^current_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
  end

  test "is idempotent" do
    legacy_value = encrypt_with(@legacy_repo_key, "sk-online-123")
    insert_setting("__encrypted_ai.online.api_key", legacy_value)

    assert {:ok, %{migrated: 1, failed: 0}} = SecretMigration.migrate_legacy_secrets()
    %Setting{value: migrated_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")

    assert {:ok, %{migrated: 0, failed: 0}} = SecretMigration.migrate_legacy_secrets()
    assert %Setting{value: ^migrated_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
  end

  test "leaves undecryptable rows in place and reports them" do
    unknown_value = encrypt_with(:crypto.strong_rand_bytes(32), "lost-secret")
    insert_setting("__encrypted_ai.online.api_key", unknown_value)

    log =
      capture_log(fn ->
        assert {:ok, %{migrated: 0, failed: 1}} = SecretMigration.migrate_legacy_secrets()
      end)

    assert log =~ "__encrypted_ai.online.api_key"
    assert %Setting{value: ^unknown_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
  end

  test "ignores settings that are not encrypted secrets" do
    insert_setting("ai.online.url", "https://api.example.test/v1")

    assert {:ok, %{migrated: 0, failed: 0}} = SecretMigration.migrate_legacy_secrets()

    assert %Setting{value: "https://api.example.test/v1"} = Repo.get(Setting, "ai.online.url")
  end

  test "runs as part of repo bootstrap" do
    legacy_value = encrypt_with(@legacy_repo_key, "sk-bootstrap-123")
    insert_setting("__encrypted_ai.online.api_key", legacy_value)

    assert :ok = BDS.RepoBootstrap.ensure_ready(migrate?: false)

    %Setting{value: new_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
    refute new_value == legacy_value
    assert {:ok, "sk-bootstrap-123"} = SecretBackend.decrypt_with_current_key(new_value)
  end
end
