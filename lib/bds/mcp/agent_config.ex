defmodule BDS.MCP.AgentConfig do
  @moduledoc false

  @server_name "bDS"

  def add_to_config(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    home_dir = Keyword.get(opts, :home_dir, System.user_home!())
    config_path = config_path(agent, home_dir)
    command = Keyword.get(opts, :command, default_command(opts))
    args = Keyword.get(opts, :args, default_args(opts))

    with :ok <- ensure_config_dir(config_path),
         {:ok, config} <- read_config(config_path),
         updated <- merge_config(agent, config, command, args),
         :ok <- write_config(config_path, updated) do
      {:ok, %{config_path: config_path, server_name: @server_name}}
    end
  end

  def remove_from_config(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    home_dir = Keyword.get(opts, :home_dir, System.user_home!())
    config_path = config_path(agent, home_dir)

    with :ok <- ensure_config_dir(config_path),
         {:ok, config} <- read_config(config_path),
         updated <- remove_server_entry(agent, config),
         :ok <- write_config(config_path, updated) do
      {:ok, %{config_path: config_path, server_name: @server_name}}
    end
  end

  def config_path(:claude_code, home_dir), do: Path.join(home_dir, ".claude.json")
  def config_path(:github_copilot, home_dir), do: Path.join([home_dir, "Library", "Application Support", "Code", "User", "mcp.json"])

  def packaged_executable_path(install_root, platform) when is_binary(install_root) do
    executable_name =
      case normalize_platform(platform) do
        :windows -> "bds-mcp.bat"
        _other -> "bds-mcp"
      end

    Path.join([install_root, "mcp", "bin", executable_name])
  end

  defp default_command(opts) do
    install_root = Keyword.fetch!(opts, :install_root)
    platform = Keyword.get(opts, :platform, current_platform())
    packaged_executable_path(install_root, platform)
  end

  defp default_args(_opts), do: []

  defp read_config(path) do
    cond do
      File.exists?(path) ->
        with {:ok, contents} <- read_config_file(path),
             {:ok, config} <- Jason.decode(contents) do
          {:ok, config}
        else
          {:error, %Jason.DecodeError{} = reason} -> {:error, {:decode_config, path, reason}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, %{}}
    end
  end

  defp ensure_config_dir(config_path) do
    case File.mkdir_p(Path.dirname(config_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_config_dir, Path.dirname(config_path), reason}}
    end
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_config, path, reason}}
    end
  end

  defp write_config(path, config) do
    case File.write(path, Jason.encode!(config, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_config, path, reason}}
    end
  end

  defp merge_config(:github_copilot, config, command, args) do
    servers = Map.get(config, "servers", %{})

    Map.put(config, "servers", Map.put(servers, @server_name, %{"type" => "stdio", "command" => command, "args" => args}))
  end

  defp merge_config(:claude_code, config, command, args) do
    servers = Map.get(config, "mcpServers", %{})
    Map.put(config, "mcpServers", Map.put(servers, @server_name, %{"command" => command, "args" => args}))
  end

  defp remove_server_entry(:github_copilot, config) do
    servers =
      config
      |> Map.get("servers", %{})
      |> Map.delete(@server_name)

    Map.put(config, "servers", servers)
  end

  defp remove_server_entry(:claude_code, config) do
    servers =
      config
      |> Map.get("mcpServers", %{})
      |> Map.delete(@server_name)

    Map.put(config, "mcpServers", servers)
  end

  defp current_platform do
    case :os.type() do
      {:win32, _type} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _type} -> :linux
    end
  end

  defp normalize_platform(:darwin), do: :macos
  defp normalize_platform(platform), do: platform
end
