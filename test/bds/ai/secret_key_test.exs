defmodule BDS.AI.SecretKeyTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias BDS.AI.SecretKey

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

  defp tmp_key_path do
    Path.join([
      System.tmp_dir!(),
      "bds-secret-key-test-#{System.unique_integer([:positive])}",
      "ai_secret.key"
    ])
  end

  describe "configured key override" do
    test "uses the first 32 bytes of an explicitly configured key" do
      Application.put_env(:bds, :ai_secret_key, String.duplicate("k", 40))

      assert {:ok, key} = SecretKey.fetch()
      assert key == String.duplicate("k", 32)
    end

    test "rejects a configured key that is too short instead of falling back" do
      Application.put_env(:bds, :ai_secret_key, "too-short")

      assert {:error, {:invalid_configured_key, _detail}} = SecretKey.fetch()
    end
  end

  describe "file strategy" do
    setup do
      Application.delete_env(:bds, :ai_secret_key)
      path = tmp_key_path()
      Application.put_env(:bds, SecretKey, strategy: :file, key_file_path: path)
      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
      {:ok, path: path}
    end

    test "generates a random 32-byte key file with 0600 permissions on first use", %{path: path} do
      assert {:ok, key} = SecretKey.fetch()
      assert byte_size(key) == 32

      assert File.exists?(path)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
      assert {:ok, ^key} = path |> File.read!() |> String.trim() |> Base.decode64()
    end

    test "returns the same key across cache resets by re-reading the file" do
      assert {:ok, key} = SecretKey.fetch()
      SecretKey.reset_cache()
      assert {:ok, ^key} = SecretKey.fetch()
    end

    test "reads an existing key file", %{path: path} do
      key = :crypto.strong_rand_bytes(32)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Base.encode64(key) <> "\n")

      assert {:ok, ^key} = SecretKey.fetch()
    end

    test "errors on a corrupt key file instead of overwriting it", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not-valid-base64!!")

      assert {:error, {:key_file_corrupt, ^path}} = SecretKey.fetch()
      assert File.read!(path) == "not-valid-base64!!"
    end

    test "fails loudly when the key file location is not writable", %{path: path} do
      blocking_file = Path.dirname(path)
      File.mkdir_p!(Path.dirname(blocking_file))
      File.write!(blocking_file, "occupied")

      assert {:error, _reason} = SecretKey.fetch()
    end
  end

  describe "keychain strategy" do
    setup do
      Application.delete_env(:bds, :ai_secret_key)
      :ok
    end

    test "returns the stored key when the keychain item exists" do
      key = :crypto.strong_rand_bytes(32)

      runner = fn "security", ["find-generic-password" | _rest], _opts ->
        {Base.encode64(key) <> "\n", 0}
      end

      Application.put_env(:bds, SecretKey, strategy: :keychain, command_runner: runner)

      assert {:ok, ^key} = SecretKey.fetch()
    end

    test "creates and stores a new key when the keychain item is missing" do
      test_pid = self()

      runner = fn "security", [verb | rest], _opts ->
        case verb do
          "find-generic-password" ->
            {"security: SecKeychainSearchCopyNext: The specified item could not be found.", 44}

          "add-generic-password" ->
            send(test_pid, {:keychain_add, rest})
            {"", 0}
        end
      end

      Application.put_env(:bds, SecretKey, strategy: :keychain, command_runner: runner)

      assert {:ok, key} = SecretKey.fetch()
      assert byte_size(key) == 32

      assert_received {:keychain_add, add_args}
      assert Base.encode64(key) in add_args
    end

    test "falls back to the key file when the keychain is unavailable" do
      path = tmp_key_path()
      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      runner = fn "security", _args, _opts -> {"security: unknown error", 1} end

      Application.put_env(:bds, SecretKey,
        strategy: :keychain,
        command_runner: runner,
        key_file_path: path
      )

      assert {:ok, key} = SecretKey.fetch()
      assert byte_size(key) == 32
      assert File.exists?(path)
    end

    test "caches the resolved key so the keychain is not queried per call" do
      test_pid = self()
      key = :crypto.strong_rand_bytes(32)

      runner = fn "security", ["find-generic-password" | _rest], _opts ->
        send(test_pid, :keychain_find)
        {Base.encode64(key), 0}
      end

      Application.put_env(:bds, SecretKey, strategy: :keychain, command_runner: runner)

      assert {:ok, ^key} = SecretKey.fetch()
      assert {:ok, ^key} = SecretKey.fetch()

      assert_received :keychain_find
      refute_received :keychain_find
    end
  end
end
