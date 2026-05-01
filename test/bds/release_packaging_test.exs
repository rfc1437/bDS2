defmodule BDS.ReleasePackagingTest do
  use ExUnit.Case, async: false

  alias BDS.ReleasePackaging

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "bds-release-packaging-#{System.unique_integer([:positive])}")

    output_dir = Path.join(base_dir, "dist")
    app_release = Path.join(base_dir, "rel/bds")
    mcp_release = Path.join(base_dir, "rel/bds_mcp")

    File.mkdir_p!(Path.join(app_release, "bin"))
    File.mkdir_p!(Path.join(mcp_release, "mcp/bin"))
    File.write!(Path.join(app_release, "bin/bds"), "app-release")
    File.write!(Path.join(mcp_release, "mcp/bin/bds-mcp"), "mcp-release")

    on_exit(fn -> File.rm_rf(base_dir) end)

    %{
      base_dir: base_dir,
      output_dir: output_dir,
      app_release: app_release,
      mcp_release: mcp_release
    }
  end

  test "build metadata uses a clean future-app payload layout" do
    metadata = ReleasePackaging.build_metadata(:macos, "0.1.0", "/tmp/out")

    assert metadata.platform == :macos
    assert metadata.version == "0.1.0"
    assert metadata.archive_path =~ ".tar.gz"
    assert metadata.payload_root =~ "bds2-macos-0.1.0"
    assert metadata.resources_root == Path.join(metadata.payload_root, "resources")
    assert metadata.mcp_root == Path.join(metadata.payload_root, "resources/mcp")
    assert metadata.app_root == Path.join(metadata.payload_root, "app")
  end

  test "package creates payload manifest and copies app and mcp releases", context do
    assert {:ok, metadata} =
             ReleasePackaging.package(
               platform: :macos,
               version: "0.1.0",
               output_dir: context.output_dir,
               app_release_source: context.app_release,
               mcp_release_source: context.mcp_release
             )

    assert File.exists?(Path.join(metadata.app_root, "bin/bds"))
    assert File.exists?(Path.join(metadata.mcp_root, "bin/bds-mcp"))
    assert File.exists?(Path.join(metadata.payload_root, "manifest.json"))

    manifest =
      metadata.payload_root |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    assert manifest == %{
             "platform" => "macos",
             "version" => "0.1.0",
             "layout" => %{
               "app" => "app",
               "resources" => "resources",
               "mcp" => "resources/mcp"
             }
           }
  end

  test "package creates a platform archive for redistribution", context do
    assert {:ok, metadata} =
             ReleasePackaging.package(
               platform: :windows,
               version: "0.1.0",
               output_dir: context.output_dir,
               app_release_source: context.app_release,
               mcp_release_source: context.mcp_release
             )

    assert File.exists?(metadata.archive_path)
    assert String.ends_with?(metadata.archive_path, ".zip")
  end
end
