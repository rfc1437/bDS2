defmodule Mix.Tasks.Bds.Mcp do
  @moduledoc false

  use Mix.Task

  @shortdoc "Runs the bDS MCP server over stdio or localhost HTTP"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--http", port] ->
        {:ok, _server} = BDS.MCP.Server.start(String.to_integer(port))
        Process.sleep(:infinity)

      ["--http"] ->
        {:ok, _server} = BDS.MCP.Server.start(0)
        Process.sleep(:infinity)

      _other ->
        BDS.MCP.Stdio.main()
    end
  end
end
