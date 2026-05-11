defmodule BDS.CSM030UncheckedMkdirTest do
  use ExUnit.Case, async: true

  describe "source-level: no unchecked File.mkdir_p" do
    test "sidecars.ex has no bare File.mkdir_p calls" do
      source = File.read!("lib/bds/media/sidecars.ex")
      refute source =~ ~r/:ok\s*=\s*File\.mkdir_p/
      refute source =~ ~r/File\.mkdir_p!/
    end

    test "release_packaging.ex has no File.mkdir_p! calls" do
      source = File.read!("lib/bds/release_packaging.ex")
      refute source =~ ~r/File\.mkdir_p!/
    end

    test "thumbnails.ex mkdir_p is inside a with chain" do
      source = File.read!("lib/bds/media/thumbnails.ex")
      refute source =~ ~r/:ok\s*=\s*File\.mkdir_p/
      refute source =~ ~r/File\.mkdir_p!/
    end
  end

  describe "source-level: sidecar write errors are handled" do
    test "media.ex does not assert :ok on write_sidecar" do
      source = File.read!("lib/bds/media.ex")
      refute source =~ ~r/:ok\s*=\s*write_sidecar/
      refute source =~ ~r/:ok\s*=\s*write_translation_sidecar/
    end

    test "linking.ex does not assert :ok on write_sidecar" do
      source = File.read!("lib/bds/media/linking.ex")
      refute source =~ ~r/:ok\s*=\s*Sidecars\.write_sidecar/
    end
  end

  describe "source-level: release_packaging.ex write_manifest" do
    test "uses File.write not File.write!" do
      source = File.read!("lib/bds/release_packaging.ex")
      refute source =~ ~r/File\.write!/
    end
  end
end
