defmodule BDS.MCP.AgentConfig do
  @moduledoc false

  @server_name "bDS"

  def add_to_config(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    home_dir = Keyword.get(opts, :home_dir, System.user_home!())
    config_path = config_path(agent, home_dir)
    command = Keyword.get(opts, :command, default_command(opts))
    args = Keyword.get(opts, :args, default_args(opts))

    File.mkdir_p!(Path.dirname(config_path))

    config = read_config(config_path)
    updated = merge_config(agent, config, command, args)
    File.write!(config_path, Jason.encode!(updated, pretty: true))

    {:ok, %{config_path: config_path, server_name: @server_name}}
  end

  def config_path(:claude_code, home_dir), do: Path.join(home_dir, ".claude.json")
  def config_path(:github_copilot, home_dir), do: Path.join([home_dir, "Library", "Application Support", "Code", "User", "mcp.json"])

  defp default_command(opts) do
    Keyword.get(opts, :script_path, repo_script_path())
  end

  defp default_args(_opts), do: []

  defp repo_script_path do
    Path.expand("../../../bin/bds-mcp", __DIR__)
  end

  defp read_config(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
    else
      %{}
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
end
