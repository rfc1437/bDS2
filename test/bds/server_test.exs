defmodule BDS.ServerTest do
  use ExUnit.Case, async: false

  alias BDS.Server

  describe "mode/1" do
    test "defaults to :desktop" do
      assert Server.mode(nil) == :desktop
      assert Server.mode("") == :desktop
    end

    test "recognizes server mode" do
      assert Server.mode("server") == :server
      assert Server.mode("SERVER") == :server
    end

    test "recognizes tui mode" do
      assert Server.mode("tui") == :tui
    end

    test "unknown values fall back to :desktop" do
      assert Server.mode("garbage") == :desktop
    end
  end

  describe "effective_mode/3" do
    test "desktop stays desktop when a display is available" do
      assert Server.effective_mode(:desktop, {:unix, :linux}, %{"DISPLAY" => ":0"}) == :desktop

      assert Server.effective_mode(:desktop, {:unix, :linux}, %{"WAYLAND_DISPLAY" => "wayland-0"}) ==
               :desktop
    end

    test "desktop falls back to the TUI on unix without a display" do
      assert Server.effective_mode(:desktop, {:unix, :linux}, %{}) == :tui
      assert Server.effective_mode(:desktop, {:unix, :linux}, %{"DISPLAY" => ""}) == :tui
      assert Server.effective_mode(:desktop, {:unix, :freebsd}, %{"WAYLAND_DISPLAY" => ""}) == :tui
    end

    test "macOS keeps the GUI locally but falls back to the TUI over ssh" do
      # macOS has no DISPLAY variable; a local launch always has a
      # graphical session, an ssh session never does.
      assert Server.effective_mode(:desktop, {:unix, :darwin}, %{}) == :desktop

      assert Server.effective_mode(:desktop, {:unix, :darwin}, %{
               "SSH_CONNECTION" => "10.0.0.5 52000 10.0.0.9 22"
             }) == :tui

      assert Server.effective_mode(:desktop, {:unix, :darwin}, %{"SSH_TTY" => "/dev/ttys003"}) ==
               :tui

      assert Server.effective_mode(:desktop, {:unix, :darwin}, %{"SSH_CLIENT" => "10.0.0.5"}) ==
               :tui

      assert Server.effective_mode(:desktop, {:unix, :darwin}, %{"SSH_CONNECTION" => ""}) ==
               :desktop
    end

    test "linux over ssh with a forwarded display keeps the GUI" do
      env = %{"SSH_CONNECTION" => "10.0.0.5 52000 10.0.0.9 22", "DISPLAY" => "localhost:10.0"}
      assert Server.effective_mode(:desktop, {:unix, :linux}, env) == :desktop
    end

    test "Windows never falls back" do
      assert Server.effective_mode(:desktop, {:win32, :nt}, %{}) == :desktop

      assert Server.effective_mode(:desktop, {:win32, :nt}, %{"SSH_CONNECTION" => "10.0.0.5"}) ==
               :desktop
    end

    test "explicit server and tui modes are untouched" do
      assert Server.effective_mode(:server, {:unix, :linux}, %{}) == :server
      assert Server.effective_mode(:tui, {:unix, :linux}, %{"DISPLAY" => ":0"}) == :tui
      assert Server.effective_mode(:server, {:unix, :darwin}, %{"DISPLAY" => ":0"}) == :server
    end
  end

  describe "prepare_boot_env/1" do
    setup do
      original = System.get_env("NO_WX")
      System.delete_env("NO_WX")

      on_exit(fn ->
        if original, do: System.put_env("NO_WX", original), else: System.delete_env("NO_WX")
      end)

      :ok
    end

    test "non-desktop modes disable wx so the :desktop dep boots inert" do
      assert Server.prepare_boot_env(:tui, fn -> :ok end) == :tui
      assert System.get_env("NO_WX") == "1"

      System.delete_env("NO_WX")
      assert Server.prepare_boot_env(:server, fn -> :ok end) == :server
      assert System.get_env("NO_WX") == "1"
    end

    test "desktop mode leaves wx enabled" do
      assert Server.prepare_boot_env(:desktop, fn -> :ok end) == :desktop
      assert System.get_env("NO_WX") == nil
    end

    test "tui mode silences terminal writers; desktop and server modes keep them" do
      original = Application.get_env(:bumblebee, :progress_bar_enabled)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:bumblebee, :progress_bar_enabled)
        else
          Application.put_env(:bumblebee, :progress_bar_enabled, original)
        end
      end)

      parent = self()

      assert Server.prepare_boot_env(:tui, fn -> send(parent, :redirected) end) == :tui
      assert Application.get_env(:bumblebee, :progress_bar_enabled) == false
      assert_received :redirected

      Server.prepare_boot_env(:desktop, fn -> send(parent, :redirected) end)
      Server.prepare_boot_env(:server, fn -> send(parent, :redirected) end)
      refute_received :redirected
    end
  end

  describe "tui logging redirect" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bds-tui-log-#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "bds.log")
      Application.put_env(:bds, :tui_log_file, log_file)

      on_exit(fn ->
        Application.delete_env(:bds, :tui_log_file)
        File.rm_rf(dir)
      end)

      {:ok, log_file: log_file}
    end

    test "tui_log_file defaults to the private app dir and honors the override", %{
      log_file: log_file
    } do
      assert Server.tui_log_file() == log_file

      Application.delete_env(:bds, :tui_log_file)
      assert Server.tui_log_file() == Path.join([BDS.Projects.private_dir(), "logs", "bds.log"])
    end

    test "redirect_logging_to_file swaps the default handler to a rotating file handler", %{
      log_file: log_file
    } do
      {:ok, original} = :logger.get_handler_config(:default)

      on_exit(fn ->
        _ = :logger.remove_handler(:default)

        :ok =
          :logger.add_handler(
            :default,
            original.module,
            Map.take(original, [:level, :filters, :filter_default, :formatter, :config])
          )
      end)

      assert Server.redirect_logging_to_file() == :ok

      {:ok, handler} = :logger.get_handler_config(:default)
      assert handler.module == :logger_std_h
      assert handler.config.file == String.to_charlist(log_file)
      assert handler.config.max_no_bytes > 0
      # The swap must keep the Elixir log formatter, not fall back to OTP's.
      assert handler.formatter == original.formatter
    end
  end

  describe "ensure_ssh_dir!/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bds-ssh-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "creates the directory and an empty authorized_keys file", %{dir: dir} do
      assert Server.ensure_ssh_dir!(dir) == dir
      assert File.dir?(dir)

      keys_path = Path.join(dir, "authorized_keys")
      assert File.exists?(keys_path)
      assert File.read!(keys_path) == ""

      %File.Stat{mode: mode} = File.stat!(keys_path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "leaves an existing authorized_keys file untouched", %{dir: dir} do
      File.mkdir_p!(dir)
      keys_path = Path.join(dir, "authorized_keys")
      File.write!(keys_path, "ssh-ed25519 AAAA... user@host\n")

      Server.ensure_ssh_dir!(dir)

      assert File.read!(keys_path) == "ssh-ed25519 AAAA... user@host\n"
    end
  end

  describe "daemon_opts/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bds-ssh-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "serves the TUI app over public-key auth only, with GUI tunneling", %{dir: dir} do
      opts = Server.daemon_opts(dir)

      assert opts[:mod] == BDS.TUI
      assert opts[:auth_methods] == ~c"publickey"
      assert opts[:tcpip_tunnel_out] == true
      refute Keyword.has_key?(opts, :pwdfun)

      assert opts[:system_dir] == String.to_charlist(dir)
      assert opts[:user_dir] == String.to_charlist(dir)
    end

    test "generates a host key on first use and reuses it", %{dir: dir} do
      Server.daemon_opts(dir)
      key_path = Path.join(dir, "ssh_host_rsa_key")
      assert File.exists?(key_path)
      first = File.read!(key_path)

      Server.daemon_opts(dir)
      assert File.read!(key_path) == first
    end

    test "uses the configured SSH port", %{dir: dir} do
      assert Server.daemon_opts(dir)[:port] == Application.get_env(:bds, :server)[:ssh_port]
    end
  end

  describe "BDS.Application.mode_children/2" do
    test "server mode starts endpoint, cli sync watcher, and the SSH daemon" do
      children = BDS.Application.mode_children(:server, :prod)

      assert {BDS.Desktop.Server, []} in children
      assert BDS.CliSync.Watcher in children
      # BDS.Server wraps ExRatatui.SSH.Daemon, deferring key generation to
      # process start so building this list never touches the data dir.
      assert BDS.Server in children
    end

    test "server mode starts no wx window children" do
      children = BDS.Application.mode_children(:server, :prod)

      refute Enum.any?(children, fn
               {Desktop.Window, _} -> true
               _other -> false
             end)
    end

    test "tui mode is the server plus a local TUI that stops the VM on quit" do
      assert BDS.Application.mode_children(:tui, :prod) ==
               BDS.Application.mode_children(:server, :prod) ++
                 [{BDS.TUI, [stop_vm_on_exit: true]}]
    end

    test "desktop mode delegates to desktop_children" do
      assert BDS.Application.mode_children(:desktop, :test) ==
               BDS.Application.desktop_children(:test)
    end
  end
end
