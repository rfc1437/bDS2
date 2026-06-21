defmodule BDS.AI.SecretBackend do
  @moduledoc """
  Encrypts and decrypts AI provider secrets (AES-256-GCM) with the
  machine-local master key resolved by `BDS.AI.SecretKey`.

  Values written by earlier releases — encrypted with key material that
  shipped in the repository, or with the deterministic node-name fallback —
  are still readable: `decrypt/1` falls back to the legacy keys, and
  `BDS.AI.SecretMigration` re-encrypts such rows at boot. When no master key
  can be obtained, both operations return `{:error, :secret_key_unavailable}`
  instead of degrading to a weaker key.
  """

  require Logger

  alias BDS.AI.SecretKey

  @aad "bds-ai-secret"

  # Key material shipped in the repository before TD-01. Retained only so
  # existing user databases can be read and re-encrypted by
  # BDS.AI.SecretMigration; remove both together in a future release.
  @legacy_repo_key binary_part(
                     "bds_desktop_shell_secret_key_base_64_chars_minimum_seed_value_001",
                     0,
                     32
                   )

  @spec encrypt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(value) when is_binary(value) do
    with {:ok, key} <- secret_key() do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

      {:ok, Base.encode64(iv <> tag <> ciphertext)}
    end
  end

  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(encoded) when is_binary(encoded) do
    with {:ok, key} <- secret_key() do
      decrypt_with_fallback(encoded, key)
    end
  end

  @doc """
  Decrypts strictly with the current master key — no legacy fallback. Used by
  `BDS.AI.SecretMigration` to detect rows that still need re-encryption.
  """
  @spec decrypt_with_current_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_with_current_key(encoded) when is_binary(encoded) do
    with {:ok, key} <- secret_key() do
      decrypt_with(encoded, key)
    end
  end

  @doc """
  Attempts decryption with the legacy keys used by earlier releases.
  """
  @spec decrypt_legacy(String.t()) :: {:ok, String.t()} | {:error, :invalid_ciphertext}
  def decrypt_legacy(encoded) when is_binary(encoded) do
    Enum.find_value(legacy_keys(), {:error, :invalid_ciphertext}, fn key ->
      case decrypt_with(encoded, key) do
        {:ok, plaintext} -> {:ok, plaintext}
        {:error, :invalid_ciphertext} -> nil
      end
    end)
  end

  defp legacy_keys do
    [
      @legacy_repo_key,
      :crypto.hash(:sha256, Atom.to_string(node()) <> ":bds:ai")
    ]
  end

  defp decrypt_with_fallback(encoded, key) do
    case decrypt_with(encoded, key) do
      {:ok, _plaintext} = ok -> ok
      {:error, :invalid_ciphertext} -> decrypt_legacy(encoded)
    end
  end

  defp decrypt_with(encoded, key) do
    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> <- binary,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _other -> {:error, :invalid_ciphertext}
    end
  end

  defp secret_key do
    case SecretKey.fetch() do
      {:ok, key} ->
        {:ok, key}

      {:error, reason} ->
        Logger.error("AI secret key unavailable: #{inspect(reason)}")
        {:error, :secret_key_unavailable}
    end
  end
end
