defmodule Mix.Tasks.Bds.Package do
  @moduledoc false

  use Mix.Task

  @shortdoc "Packages built releases into a redistributable platform payload"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [output: :string, version: :string, app_release: :string, mcp_release: :string]
      )

    platform = positional |> List.first() |> normalize_platform_arg()
    version = opts[:version] || Mix.Project.config()[:version]
    env_name = Atom.to_string(Mix.env())

    package_opts = [
      platform: platform,
      version: version,
      output_dir: opts[:output] || Path.expand("dist/#{platform}", File.cwd!()),
      app_release_source: opts[:app_release] || Path.expand("_build/#{env_name}/rel/bds", File.cwd!()),
      mcp_release_source: opts[:mcp_release] || Path.expand("_build/#{env_name}/rel/bds_mcp", File.cwd!())
    ]

    case BDS.ReleasePackaging.package(package_opts) do
      {:ok, metadata} ->
        Mix.shell().info("Packaged #{metadata.payload_name} at #{metadata.archive_path}")

      {:error, reason} ->
        Mix.raise("Packaging failed: #{inspect(reason)}")
    end
  end

  defp normalize_platform_arg(nil), do: current_platform()
  defp normalize_platform_arg("macos"), do: :macos
  defp normalize_platform_arg("linux"), do: :linux
  defp normalize_platform_arg("windows"), do: :windows
  defp normalize_platform_arg(other), do: Mix.raise("Unsupported platform #{inspect(other)}")

  defp current_platform do
    case :os.type() do
      {:win32, _type} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _type} -> :linux
    end
  end
end