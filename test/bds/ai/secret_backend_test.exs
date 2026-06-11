defmodule BDS.AI.SecretBackendTest do
  use ExUnit.Case, async: false

  alias BDS.AI.SecretBackend
  alias BDS.AI.SecretKey

  # Key material shipped in the repository before TD-01. Kept here only to
  # prove that secrets stored by earlier releases remain readable.
  @legacy_repo_key binary_part(
                     "bds_desktop_shell_secret_key_base_64_chars_minimum_seed_value_001",
                     0,
                     32
                   )

  @aad "bds-ai-secret"

  setup do
    original_key = Application.fetch_env(:bds, :ai_secret_key)
    original_config = Application.fetch_env(:bds, SecretKey)

    on_exit(fn ->
      restore_env(:ai_secret_key, original_key)
      restore_env(SecretKey, original_config)
      SecretKey.reset_cache()
    end)

    SecretKey.reset_cache()
    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:bds, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:bds, key)

  defp encrypt_with(key, value) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)
    Base.encode64(iv <> tag <> ciphertext)
  end

  test "round-trips a secret with the current key" do
    assert {:ok, encrypted} = SecretBackend.encrypt("sk-live-12345")
    refute encrypted == "sk-live-12345"
    assert {:ok, "sk-live-12345"} = SecretBackend.decrypt(encrypted)
  end

  test "rejects garbage ciphertext" do
    assert {:error, :invalid_ciphertext} = SecretBackend.decrypt("not-encrypted")
    assert {:error, :invalid_ciphertext} = SecretBackend.decrypt(Base.encode64("too-short"))
  end

  test "still decrypts values encrypted with the legacy repo-baked key" do
    legacy_value = encrypt_with(@legacy_repo_key, "legacy-online-key")

    assert {:ok, "legacy-online-key"} = SecretBackend.decrypt(legacy_value)
  end

  test "still decrypts values encrypted with the legacy node-name key" do
    node_key = :crypto.hash(:sha256, Atom.to_string(node()) <> ":bds:ai")
    legacy_value = encrypt_with(node_key, "legacy-node-key-secret")

    assert {:ok, "legacy-node-key-secret"} = SecretBackend.decrypt(legacy_value)
  end

  test "decrypt_with_current_key does not accept legacy ciphertexts" do
    legacy_value = encrypt_with(@legacy_repo_key, "legacy-secret")

    assert {:error, :invalid_ciphertext} = SecretBackend.decrypt_with_current_key(legacy_value)

    assert {:ok, current_value} = SecretBackend.encrypt("current-secret")
    assert {:ok, "current-secret"} = SecretBackend.decrypt_with_current_key(current_value)
  end

  test "fails loudly when no secret key can be obtained" do
    Application.delete_env(:bds, :ai_secret_key)

    blocked_dir = Path.join(System.tmp_dir!(), "bds-blocked-#{System.unique_integer([:positive])}")
    File.write!(blocked_dir, "occupied")
    on_exit(fn -> File.rm(blocked_dir) end)

    Application.put_env(:bds, SecretKey,
      strategy: :file,
      key_file_path: Path.join(blocked_dir, "ai_secret.key")
    )

    assert {:error, :secret_key_unavailable} = SecretBackend.encrypt("anything")

    valid_looking = encrypt_with(:crypto.strong_rand_bytes(32), "anything")
    assert {:error, :secret_key_unavailable} = SecretBackend.decrypt(valid_looking)
  end
end
