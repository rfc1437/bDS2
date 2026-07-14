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

    test "tui mode is the server plus a local TUI" do
      assert BDS.Application.mode_children(:tui, :prod) ==
               BDS.Application.mode_children(:server, :prod) ++ [{BDS.TUI, []}]
    end

    test "desktop mode delegates to desktop_children" do
      assert BDS.Application.mode_children(:desktop, :test) ==
               BDS.Application.desktop_children(:test)
    end
  end
end
