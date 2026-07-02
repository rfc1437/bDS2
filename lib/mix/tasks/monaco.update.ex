defmodule Mix.Tasks.Monaco.Update do
  @shortdoc "Update monaco-editor to a given version and rebuild its bundle"

  @moduledoc """
  Update the monaco-editor npm package and rebuild the Monaco ESM bundle.

      mix monaco.update 0.55.1

  This task:

  1. Runs `npm install monaco-editor@<version> --save-dev`
  2. Removes the old Monaco bundle assets
  3. Rebuilds the Monaco main and worker bundles via esbuild (both dev and minified)

  Use `mix monaco.version` to check the result.

  See `npm view monaco-editor` or https://www.npmjs.com/package/monaco-editor
  for available versions.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case args do
      [] ->
        Mix.shell().error("Missing version argument.")
        Mix.shell().info("Usage: mix monaco.update <version>")
        Mix.shell().info("Example: mix monaco.update 0.55.1")
        Mix.raise("missing Monaco version argument")

      [version] ->
        do_update(version)

      _ ->
        Mix.shell().error("Too many arguments. Usage: mix monaco.update <version>")
        Mix.raise("too many arguments for mix monaco.update")
    end
  end

  defp do_update(version) do
    current = current_version()
    Mix.shell().info("Updating monaco-editor: #{current} → #{version}")

    # 1. npm install
    {_, 0} = System.cmd("npm", ["install", "monaco-editor@#{version}", "--save-dev"], into: IO.stream(:stdio, :line))
    {_, 0} = System.cmd("npm", ["install"], into: IO.stream(:stdio, :line))

    # 2. Clean old bundle
    monaco_js = Path.join(File.cwd!(), "priv/static/assets/monaco.js")
    monaco_css = Path.join(File.cwd!(), "priv/static/assets/monaco.css")
    monaco_workers = Path.join(File.cwd!(), "priv/static/assets/monaco")

    for path <- [monaco_js, monaco_css, monaco_workers] do
      if File.exists?(path) do
        File.rm_rf!(path)
      end
    end

    Mix.shell().info("Removed old Monaco bundle assets")

    # 3. Rebuild via esbuild (dev + minified)
    run_esbuild(["monaco"])
    run_esbuild(["monaco_workers"])
    run_esbuild(["monaco", "--minify"])
    run_esbuild(["monaco_workers", "--minify"])

    # 4. Verify
    new = current_version()
    Mix.shell().info("monaco-editor is now at #{new}")
  end

  defp run_esbuild(args) do
    Mix.Task.run("esbuild", args)
  end

  defp current_version do
    lock = Path.join(File.cwd!(), "package-lock.json")

    case File.read(lock) do
      {:ok, content} ->
        data = Jason.decode!(content)

        case Map.get(Map.get(data, "packages", %{}), "node_modules/monaco-editor") do
          %{"version" => v} -> v
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end
end
