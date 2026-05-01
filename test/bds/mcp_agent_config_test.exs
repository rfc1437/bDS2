defmodule BDS.MCPAgentConfigTest do
  use ExUnit.Case, async: false

  alias BDS.MCP.AgentConfig

  setup do
    home_dir = Path.join(System.tmp_dir!(), "bds-mcp-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home_dir)
    on_exit(fn -> File.rm_rf(home_dir) end)
    %{home_dir: home_dir}
  end

  test "github copilot config uses VS Code mcp.json servers format with stdio entry", %{
    home_dir: home_dir
  } do
    install_root = Path.join(home_dir, "bDS2.app/Contents/Resources")
    executable_path = Path.join(install_root, "mcp/bin/bds-mcp")

    assert {:ok, result} =
             AgentConfig.add_to_config(:github_copilot,
               home_dir: home_dir,
               install_root: install_root,
               platform: :macos
             )

    assert File.exists?(result.config_path)
    written = Jason.decode!(File.read!(result.config_path))

    assert written["servers"]["bDS"] == %{
             "type" => "stdio",
             "command" => executable_path,
             "args" => []
           }
  end

  test "claude code config uses mcpServers format and preserves other entries", %{
    home_dir: home_dir
  } do
    config_path = Path.join(home_dir, ".claude.json")
    install_root = Path.join(home_dir, "dist")

    File.write!(
      config_path,
      Jason.encode!(%{"mcpServers" => %{"other" => %{"command" => "python"}}, "theme" => "dark"})
    )

    assert {:ok, result} =
             AgentConfig.add_to_config(:claude_code,
               home_dir: home_dir,
               install_root: install_root,
               platform: :linux
             )

    written = Jason.decode!(File.read!(result.config_path))
    assert written["theme"] == "dark"
    assert written["mcpServers"]["other"] == %{"command" => "python"}

    assert written["mcpServers"]["bDS"] == %{
             "command" => Path.join(install_root, "mcp/bin/bds-mcp"),
             "args" => []
           }
  end

  test "github copilot uninstall removes only the bDS server entry", %{home_dir: home_dir} do
    config_path = Path.join(home_dir, "Library/Application Support/Code/User/mcp.json")

    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      Jason.encode!(%{
        "servers" => %{
          "bDS" => %{"type" => "stdio", "command" => "/tmp/bds-mcp", "args" => []},
          "other" => %{"type" => "stdio", "command" => "python", "args" => ["server.py"]}
        },
        "theme" => "dark"
      })
    )

    assert {:ok, result} = AgentConfig.remove_from_config(:github_copilot, home_dir: home_dir)

    written = Jason.decode!(File.read!(result.config_path))
    assert written["theme"] == "dark"
    refute Map.has_key?(written["servers"], "bDS")

    assert written["servers"]["other"] == %{
             "type" => "stdio",
             "command" => "python",
             "args" => ["server.py"]
           }
  end

  test "claude code uninstall removes only the bDS server entry", %{home_dir: home_dir} do
    config_path = Path.join(home_dir, ".claude.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "mcpServers" => %{
          "bDS" => %{"command" => "/tmp/bds-mcp", "args" => []},
          "other" => %{"command" => "python", "args" => ["server.py"]}
        },
        "theme" => "dark"
      })
    )

    assert {:ok, result} = AgentConfig.remove_from_config(:claude_code, home_dir: home_dir)

    written = Jason.decode!(File.read!(result.config_path))
    assert written["theme"] == "dark"
    refute Map.has_key?(written["mcpServers"], "bDS")
    assert written["mcpServers"]["other"] == %{"command" => "python", "args" => ["server.py"]}
  end

  test "add_to_config returns an error for unreadable existing config", %{home_dir: home_dir} do
    config_path = Path.join(home_dir, ".claude.json")
    File.mkdir_p!(config_path)

    assert {:error, {:read_config, ^config_path, :eisdir}} =
             AgentConfig.add_to_config(:claude_code,
               home_dir: home_dir,
               install_root: Path.join(home_dir, "dist"),
               platform: :linux
             )
  end

  test "remove_from_config returns an error for unwritable config path", %{home_dir: home_dir} do
    config_path = Path.join(home_dir, ".claude.json")

    File.chmod!(home_dir, 0o555)
    on_exit(fn -> File.chmod!(home_dir, 0o755) end)

    assert {:error, {:write_config, ^config_path, :eacces}} =
             AgentConfig.remove_from_config(:claude_code, home_dir: home_dir)
  end

  test "packaged executable path resolves inside the distributable payload" do
    assert AgentConfig.packaged_executable_path(
             "/Applications/bDS2.app/Contents/Resources",
             :macos
           ) ==
             "/Applications/bDS2.app/Contents/Resources/mcp/bin/bds-mcp"

    assert AgentConfig.packaged_executable_path("C:/Program Files/bDS2/resources", :windows) ==
             "C:/Program Files/bDS2/resources/mcp/bin/bds-mcp.bat"

    assert AgentConfig.packaged_executable_path("/opt/bds2", :linux) ==
             "/opt/bds2/mcp/bin/bds-mcp"
  end

  test "release config exposes a dedicated distributable mcp release" do
    project = BDS.MixProject.project()
    releases = Keyword.fetch!(project, :releases)
    mcp_release = Keyword.fetch!(releases, :bds_mcp)

    assert Keyword.fetch!(project, :default_release) == :bds
    assert Keyword.fetch!(mcp_release, :include_executables_for) == [:unix, :windows]
    assert Path.join(Keyword.fetch!(mcp_release, :path), "bin") =~ "rel/bds_mcp"
  end
end
