defmodule Mix.Tasks.Monaco.Version do
  @shortdoc "Show current monaco-editor version"

  @moduledoc """
  Show the currently installed monaco-editor version.

      mix monaco.version

  Reads the version from package-lock.json. The Monaco bundle lives at
  `priv/static/assets/monaco.js` and is built via `mix esbuild monaco`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    lock = Path.join(File.cwd!(), "package-lock.json")

    case File.read(lock) do
      {:ok, content} ->
        data = Jason.decode!(content)

        version =
          case Map.get(Map.get(data, "packages", %{}), "node_modules/monaco-editor") do
            %{"version" => v} -> v
            _ -> nil
          end

        case version do
          v when is_binary(v) -> Mix.shell().info("monaco-editor: #{v}")
          nil ->
            Mix.shell().error("Could not find monaco-editor in package-lock.json")
            System.at_exit(fn _ -> System.halt(1) end)
        end

      {:error, reason} ->
        Mix.shell().error("package-lock.json not found: #{reason}")
        System.at_exit(fn _ -> System.halt(1) end)
    end
  end
end
