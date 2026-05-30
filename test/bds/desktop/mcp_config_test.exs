defmodule BDS.Desktop.ShellLive.SettingsEditor.MCPConfigTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellLive.SettingsEditor.MCPConfig

  describe "mcp_rows/0" do
    test "returns 7 agent rows" do
      rows = MCPConfig.mcp_rows()
      assert length(rows) == 7
    end

    test "has correct agent order" do
      rows = MCPConfig.mcp_rows()
      ids = Enum.map(rows, & &1.id)
      assert ids == [:claude_code, :claude_desktop, :github_copilot, :gemini_cli, :opencode, :mistral_vibe, :openai_codex]
    end

    test "Claude Code and GitHub Copilot are supported" do
      rows = MCPConfig.mcp_rows()
      claude = Enum.find(rows, &(&1.id == :claude_code))
      copilot = Enum.find(rows, &(&1.id == :github_copilot))
      assert claude.supported?
      assert copilot.supported?
    end

    test "other agents are not supported" do
      rows = MCPConfig.mcp_rows()
      unsupported = Enum.reject(rows, & &1.supported?)
      assert length(unsupported) == 5
      assert Enum.all?(unsupported, &(!&1.supported?))
    end

    test "unsupported agents have nil config_path" do
      rows = MCPConfig.mcp_rows()
      unsupported = Enum.filter(rows, &(!&1.supported?))
      assert Enum.all?(unsupported, &is_nil(&1.config_path))
    end

    test "unsupported agents have configured? false" do
      rows = MCPConfig.mcp_rows()
      unsupported = Enum.filter(rows, &(!&1.supported?))
      assert Enum.all?(unsupported, &(&1.configured? == false))
    end
  end

  describe "toggle_mcp_agent/4" do
    test "unsupported agent appends not-supported error" do
      socket = %{assigns: %{workbench: nil}}
      reload = fn s, _wb -> send(self(), :reloaded); s end
      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_appended)
        socket
      end

      MCPConfig.toggle_mcp_agent(socket, "gemini_cli", reload, append_output)

      assert_received :error_appended
      assert_received :reloaded
    end

    test "unsupported agent does not touch AgentConfig" do
      socket = %{assigns: %{workbench: nil}}
      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      assert MCPConfig.toggle_mcp_agent(socket, "opencode", reload, append_output) == socket
    end

    test "unknown agent is treated as unsupported" do
      socket = %{assigns: %{workbench: nil}}
      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_appended)
        socket
      end

      MCPConfig.toggle_mcp_agent(socket, "nonexistent_agent", reload, append_output)

      assert_received :error_appended
    end
  end
end
