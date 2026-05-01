defmodule BDS.Desktop.ShellLive.SettingsEditor.MCPConfig do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData
  alias BDS.MCP.AgentConfig

  @mcp_agents [
    %{id: :claude_code, label: "Claude Code", supported?: true},
    %{id: :claude_desktop, label: "Claude Desktop", supported?: false},
    %{id: :github_copilot, label: "GitHub Copilot", supported?: true},
    %{id: :gemini_cli, label: "Gemini CLI", supported?: false},
    %{id: :opencode, label: "OpenCode", supported?: false},
    %{id: :mistral_vibe, label: "Mistral Vibe", supported?: false},
    %{id: :openai_codex, label: "OpenAI Codex", supported?: false}
  ]

  def mcp_rows do
    Enum.map(@mcp_agents, fn agent ->
      %{
        id: agent.id,
        label: agent.label,
        supported?: agent.supported?,
        configured?: mcp_configured?(agent),
        config_path: mcp_config_path(agent)
      }
    end)
  end

  def toggle_mcp_agent(socket, agent, reload, append_output) do
    case find_mcp_agent(agent) do
      %{id: agent_id, supported?: true} = config ->
        if mcp_configured?(config) do
          {:ok, _payload} = AgentConfig.remove_from_config(agent_id)
          reload.(socket, socket.assigns.workbench)
        else
          install_root = Application.app_dir(:bds)
          {:ok, _payload} = AgentConfig.add_to_config(agent_id, install_root: install_root)
          reload.(socket, socket.assigns.workbench)
        end

      _other ->
        socket
        |> append_output.(
          translated("MCP"),
          translated("This MCP agent is not supported in the rewrite yet"),
          nil,
          "error"
        )
        |> reload.(socket.assigns.workbench)
    end
  end

  defp find_mcp_agent(agent) do
    normalized =
      agent
      |> to_string()
      |> String.to_existing_atom()

    Enum.find(@mcp_agents, &(&1.id == normalized))
  rescue
    _error -> nil
  end

  defp mcp_configured?(%{supported?: false}), do: false

  defp mcp_configured?(%{id: agent_id}) do
    path = AgentConfig.config_path(agent_id, System.user_home!())

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> mcp_server_present?(agent_id)
    else
      false
    end
  rescue
    _error -> false
  end

  defp mcp_config_path(%{supported?: false}), do: nil
  defp mcp_config_path(%{id: agent_id}), do: AgentConfig.config_path(agent_id, System.user_home!())

  defp mcp_server_present?(config, :github_copilot) do
    config
    |> Map.get("servers", %{})
    |> Map.has_key?("bDS")
  end

  defp mcp_server_present?(config, _agent_id) do
    config
    |> Map.get("mcpServers", %{})
    |> Map.has_key?("bDS")
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end
