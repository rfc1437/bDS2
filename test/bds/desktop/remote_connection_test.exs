defmodule BDS.Desktop.RemoteConnectionTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.RemoteConnection

  describe "parse_target/1" do
    test "parses user@host with default SSH port" do
      assert {:ok, %{user: "gb", host: "blog.example.com", port: 2222}} =
               RemoteConnection.parse_target("gb@blog.example.com")
    end

    test "parses an explicit SSH port" do
      assert {:ok, %{user: "gb", host: "10.0.0.5", port: 2022}} =
               RemoteConnection.parse_target("gb@10.0.0.5:2022")
    end

    test "trims whitespace" do
      assert {:ok, %{host: "h", user: "u"}} = RemoteConnection.parse_target("  u@h \n")
    end

    test "rejects targets without a user or host" do
      assert {:error, :invalid_target} = RemoteConnection.parse_target("justahost")
      assert {:error, :invalid_target} = RemoteConnection.parse_target("@host")
      assert {:error, :invalid_target} = RemoteConnection.parse_target("user@")
      assert {:error, :invalid_target} = RemoteConnection.parse_target("user@host:notaport")
    end
  end

  describe "connect/2 and disconnect/1 (fake ssh)" do
    setup do
      parent = self()

      ssh_dir =
        Path.join(System.tmp_dir!(), "bds-remote-ssh-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(ssh_dir) end)

      fake = [
        ssh_dir_fun: fn -> ssh_dir end,
        connect_fun: fn host, port, opts ->
          send(parent, {:ssh_connect, host, port, opts})
          {:ok, spawn(fn -> Process.sleep(:infinity) end)}
        end,
        tunnel_fun: fn conn, _lhost, _lport, _rhost, rport, _timeout ->
          send(parent, {:tunnel, conn, rport})
          {:ok, 54_321}
        end,
        close_fun: fn conn -> send(parent, {:ssh_close, conn}) end
      ]

      start_supervised!({RemoteConnection, name: nil, test_overrides: fake})
      |> then(&{:ok, server: &1})
    end

    test "connects with public-key auth and returns the tunneled URL", %{server: server} do
      assert {:ok, url} = RemoteConnection.connect(server, "gb@blog.example.com")
      assert url == "http://127.0.0.1:54321/"

      assert_receive {:ssh_connect, ~c"blog.example.com", 2222, opts}
      assert opts[:user] == ~c"gb"
      assert opts[:auth_methods] == ~c"publickey"
      refute Keyword.has_key?(opts, :password)

      assert_receive {:tunnel, _conn, 4010}
      assert {:connected, "gb@blog.example.com", "http://127.0.0.1:54321/"} =
               RemoteConnection.status(server)
    end

    test "disconnect closes the SSH connection", %{server: server} do
      {:ok, _url} = RemoteConnection.connect(server, "gb@blog.example.com")
      assert :ok = RemoteConnection.disconnect(server)
      assert_receive {:ssh_close, _conn}
      assert :disconnected = RemoteConnection.status(server)
    end

    test "connect errors surface as {:error, reason}", %{server: server} do
      assert {:error, :invalid_target} = RemoteConnection.connect(server, "nonsense")
    end
  end

  describe "menu integration" do
    test "the File menu offers connect and disconnect" do
      file_group = Enum.find(BDS.UI.MenuBar.default_groups(), &(&1.id == :file))
      ids = Enum.map(file_group.items, &Map.get(&1, :id))

      assert :connect_server in ids
      assert :disconnect_server in ids
    end
  end

  describe "desktop auth" do
    test "required in desktop mode, skipped in server and tui modes" do
      assert BDS.Server.desktop_auth_required?(:desktop) == true
      assert BDS.Server.desktop_auth_required?(:server) == false
      assert BDS.Server.desktop_auth_required?(:tui) == false
    end
  end
end
