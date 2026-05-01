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

  @spec mcp_rows() :: term()
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

  @spec toggle_mcp_agent(term(), term(), term(), term()) :: term()
  def toggle_mcp_agent(socket, agent, reload, append_output) do
    case find_mcp_agent(agent) do
      %{id: agent_id, supported?: true} = config ->
        result =
          if mcp_configured?(config) do
            AgentConfig.remove_from_config(agent_id)
          else
            install_root = Application.app_dir(:bds)
            AgentConfig.add_to_config(agent_id, install_root: install_root)
          end

        case result do
          {:ok, _payload} ->
            reload.(socket, socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("MCP"), format_config_error(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
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
    normalized = BDS.BoundedAtoms.mcp_agent(agent)

    Enum.find(@mcp_agents, &(&1.id == normalized))
  end

  defp format_config_error({:read_config, path, reason}) do
    translated("Could not read MCP config %{path}: %{reason}",
      path: path,
      reason: inspect(reason)
    )
  end

  defp format_config_error({:write_config, path, reason}) do
    translated("Could not write MCP config %{path}: %{reason}",
      path: path,
      reason: inspect(reason)
    )
  end

  defp format_config_error({:create_config_dir, path, reason}) do
    translated("Could not create MCP config folder %{path}: %{reason}",
      path: path,
      reason: inspect(reason)
    )
  end

  defp format_config_error({:decode_config, path, _reason}) do
    translated("Could not parse MCP config %{path}", path: path)
  end

  defp mcp_configured?(%{supported?: false}), do: false

  defp mcp_configured?(%{id: agent_id}) do
    path = AgentConfig.config_path(agent_id, System.user_home!())

    with true <- File.exists?(path),
         {:ok, contents} <- File.read(path),
         {:ok, config} <- Jason.decode(contents) do
      mcp_server_present?(config, agent_id)
    else
      _other -> false
    end
  end

  defp mcp_config_path(%{supported?: false}), do: nil

  defp mcp_config_path(%{id: agent_id}),
    do: AgentConfig.config_path(agent_id, System.user_home!())

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
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
