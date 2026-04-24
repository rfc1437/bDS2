defmodule BDS.ReleasePackaging do
  @moduledoc false

  defmodule Metadata do
    @enforce_keys [
      :platform,
      :version,
      :output_dir,
      :payload_name,
      :payload_root,
      :app_root,
      :resources_root,
      :mcp_root,
      :archive_path
    ]
    defstruct [
      :platform,
      :version,
      :output_dir,
      :payload_name,
      :payload_root,
      :app_root,
      :resources_root,
      :mcp_root,
      :archive_path
    ]
  end

  def build_metadata(platform, version, output_dir) when is_binary(version) and is_binary(output_dir) do
    normalized_platform = normalize_platform(platform)
    payload_name = "bds2-#{normalized_platform}-#{version}"
    payload_root = Path.join(output_dir, payload_name)

    %Metadata{
      platform: normalized_platform,
      version: version,
      output_dir: output_dir,
      payload_name: payload_name,
      payload_root: payload_root,
      app_root: Path.join(payload_root, "app"),
      resources_root: Path.join(payload_root, "resources"),
      mcp_root: Path.join(payload_root, "resources/mcp"),
      archive_path: Path.join(output_dir, payload_name <> archive_extension(normalized_platform))
    }
  end

  def package(opts) when is_list(opts) do
    metadata =
      build_metadata(
        Keyword.fetch!(opts, :platform),
        Keyword.fetch!(opts, :version),
        Keyword.fetch!(opts, :output_dir)
      )

    app_release_source = Keyword.fetch!(opts, :app_release_source)
    mcp_release_source = Keyword.fetch!(opts, :mcp_release_source)

    with :ok <- reset_output(metadata),
         :ok <- copy_release(app_release_source, metadata.app_root),
         :ok <- copy_release(mcp_release_source, metadata.resources_root),
         :ok <- write_manifest(metadata),
         :ok <- create_archive(metadata) do
      {:ok, metadata}
    end
  end

  defp normalize_platform(platform) when platform in [:macos, :linux, :windows], do: platform
  defp normalize_platform(:darwin), do: :macos
  defp normalize_platform(platform) when is_binary(platform), do: platform |> String.downcase() |> String.to_atom()

  defp archive_extension(:windows), do: ".zip"
  defp archive_extension(_platform), do: ".tar.gz"

  defp reset_output(metadata) do
    File.rm_rf!(metadata.payload_root)
    File.rm_rf!(metadata.archive_path)
    File.mkdir_p!(metadata.output_dir)
    :ok
  end

  defp copy_release(source, destination) do
    File.mkdir_p!(Path.dirname(destination))

    case File.cp_r(source, destination) do
      {:ok, _files} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  defp write_manifest(metadata) do
    manifest = %{
      "platform" => Atom.to_string(metadata.platform),
      "version" => metadata.version,
      "layout" => %{
        "app" => "app",
        "resources" => "resources",
        "mcp" => "resources/mcp"
      }
    }

    manifest_path = Path.join(metadata.payload_root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    :ok
  end

  defp create_archive(%Metadata{platform: :windows} = metadata) do
    relative_entries = collect_entries(metadata.payload_root)
    cwd = metadata.output_dir |> String.to_charlist()
    archive = metadata.archive_path |> String.to_charlist()
    entries = Enum.map(relative_entries, &String.to_charlist(Path.join(metadata.payload_name, &1)))

    case :zip.create(archive, entries, cwd: cwd) do
      {:ok, _archive_path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_archive(metadata) do
    case System.cmd("tar", ["-czf", metadata.archive_path, "-C", metadata.output_dir, metadata.payload_name]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:tar_failed, status, output}}
    end
  end

  defp collect_entries(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end
end
