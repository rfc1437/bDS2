defmodule BDS.AI.SecretKey do
  @moduledoc """
  Resolves the 32-byte machine-local master key that encrypts AI provider
  secrets at rest (the `SecureKeyStore` entity in `specs/ai.allium`).

  Resolution order:

  1. `config :bds, :ai_secret_key` — explicit override. Used by the test
     suite for determinism; must be at least 32 bytes (the first 32 are
     used). An invalid value is an error, never a silent fallback.
  2. A previously resolved key cached in `:persistent_term`.
  3. The OS keyring: on macOS the login Keychain via the `security` CLI; on
     other platforms — or when the Keychain is unavailable — a random key
     file under the private app dir, written with `0600` permissions.

  A fresh random key is generated and stored on first use. There is no
  deterministic fallback: when no key can be obtained or persisted, `fetch/0`
  returns `{:error, reason}` and secret encryption/decryption fails loudly
  instead of degrading to obfuscation.

  Config (`config :bds, BDS.AI.SecretKey`):

    * `:strategy` — `:auto` (default; Keychain on macOS, key file elsewhere),
      `:keychain`, or `:file`
    * `:key_file_path` — overrides the key file location
    * `:command_runner` — 3-arity replacement for `System.cmd/3` (tests)
  """

  require Logger

  @key_bytes 32
  @cache_key {__MODULE__, :key}
  @keychain_service "bDS2"
  @keychain_account "ai-secret-key"
  @keychain_not_found_status 44
  @key_file_name "ai_secret.key"

  @spec fetch() :: {:ok, binary()} | {:error, term()}
  def fetch do
    case configured_key() do
      {:ok, key} -> {:ok, key}
      {:error, _detail} = error -> error
      :unset -> cached_or_resolve()
    end
  end

  @doc "Clears the cached key so the next fetch re-resolves it (test helper)."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp configured_key do
    case Application.get_env(:bds, :ai_secret_key) do
      nil ->
        :unset

      key when is_binary(key) and byte_size(key) >= @key_bytes ->
        {:ok, binary_part(key, 0, @key_bytes)}

      other ->
        {:error, {:invalid_configured_key, "expected a binary of at least #{@key_bytes} bytes, got: #{inspect(other)}"}}
    end
  end

  defp cached_or_resolve do
    case :persistent_term.get(@cache_key, nil) do
      key when is_binary(key) ->
        {:ok, key}

      nil ->
        with {:ok, key} <- resolve() do
          :persistent_term.put(@cache_key, key)
          {:ok, key}
        end
    end
  end

  defp resolve do
    case strategy() do
      :keychain -> resolve_keychain()
      :file -> resolve_file()
    end
  end

  defp strategy do
    case config(:strategy, :auto) do
      :auto ->
        if match?({:unix, :darwin}, :os.type()), do: :keychain, else: :file

      explicit when explicit in [:keychain, :file] ->
        explicit
    end
  end

  # ─── macOS Keychain ─────────────────────────────────────────

  defp resolve_keychain do
    case keychain_find() do
      {:ok, key} ->
        {:ok, key}

      :not_found ->
        keychain_create()

      {:error, reason} ->
        Logger.warning(
          "AI secret key: macOS Keychain unavailable (#{inspect(reason)}); falling back to the key file"
        )

        resolve_file()
    end
  end

  defp keychain_find do
    case run_security([
           "find-generic-password",
           "-s",
           @keychain_service,
           "-a",
           @keychain_account,
           "-w"
         ]) do
      {output, 0} ->
        case output |> String.trim() |> Base.decode64() do
          {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
          _other -> {:error, :corrupt_keychain_item}
        end

      {_output, @keychain_not_found_status} ->
        :not_found

      {output, status} ->
        {:error, {:security_failed, status, String.trim(output)}}
    end
  end

  # The generated key passes through `security`'s argv, which is briefly
  # visible to other local processes of the same user. Accepted trade-off for
  # a single-user desktop app; `security` offers no non-interactive way to
  # take the password on stdin in one shot.
  defp keychain_create do
    key = :crypto.strong_rand_bytes(@key_bytes)

    case run_security([
           "add-generic-password",
           "-U",
           "-s",
           @keychain_service,
           "-a",
           @keychain_account,
           "-w",
           Base.encode64(key)
         ]) do
      {_output, 0} ->
        {:ok, key}

      {output, status} ->
        Logger.warning(
          "AI secret key: could not store the key in the Keychain " <>
            "(status #{status}: #{String.trim(output)}); falling back to the key file"
        )

        resolve_file()
    end
  end

  defp run_security(args) do
    runner = config(:command_runner, &default_runner/3)
    runner.("security", args, stderr_to_stdout: true)
  end

  defp default_runner(command, args, opts) do
    System.cmd(command, args, opts)
  rescue
    error in ErlangError -> {"#{command} unavailable: #{inspect(error.original)}", 127}
  end

  # ─── Key file ───────────────────────────────────────────────

  defp resolve_file do
    path = key_file_path()

    case File.read(path) do
      {:ok, contents} -> decode_key_file(contents, path)
      {:error, :enoent} -> create_key_file(path)
      {:error, reason} -> {:error, {:key_file_unreadable, path, reason}}
    end
  end

  defp decode_key_file(contents, path) do
    case contents |> String.trim() |> Base.decode64() do
      {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
      _other -> {:error, {:key_file_corrupt, path}}
    end
  end

  defp create_key_file(path) do
    key = :crypto.strong_rand_bytes(@key_bytes)
    temp_path = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, Base.encode64(key) <> "\n"),
         :ok <- File.chmod(temp_path, 0o600),
         :ok <- File.rename(temp_path, path) do
      {:ok, key}
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, {:key_file_write_failed, path, reason}}
    end
  end

  defp key_file_path do
    config(:key_file_path, nil) || Path.join(private_app_dir(), @key_file_name)
  end

  # Same private app dir as BDS.Projects.private_app_dir/0 — on macOS
  # ~/Library/Application Support/BDS2. Duplicated to keep this module free of
  # project/DB dependencies.
  defp private_app_dir do
    case :filename.basedir(:user_config, "BDS2") do
      path when is_list(path) -> List.to_string(path)
      path -> path
    end
    |> Path.expand()
  end

  defp config(key, default) do
    Application.get_env(:bds, __MODULE__, []) |> Keyword.get(key, default)
  end
end
