defmodule BDS.AI.SecretBackend do
  @moduledoc false

  @aad "bds-ai-secret"

  def encrypt(value) when is_binary(value) do
    key = secret_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

    {:ok, Base.encode64(iv <> tag <> ciphertext)}
  end

  def decrypt(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> <- binary,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             secret_key(),
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
    case Application.get_env(:bds, :ai_secret_key) do
      key when is_binary(key) and byte_size(key) >= 32 -> binary_part(key, 0, 32)
      _other -> :crypto.hash(:sha256, Atom.to_string(node()) <> ":bds:ai")
    end
  end
end
