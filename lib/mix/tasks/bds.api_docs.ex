defmodule Mix.Tasks.Bds.ApiDocs do
  use Mix.Task

  @shortdoc "Generate API.md from the Lua scripting contract"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    path = Path.expand("API.md", File.cwd!())
    File.write!(path, BDS.Scripting.ApiDocs.render())
    Mix.shell().info("Wrote #{path}")
  end
end
