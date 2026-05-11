defmodule BDS.CSM028BroadRescueTest do
  use ExUnit.Case, async: true

  describe "source-level: no broad rescue in render_macro_template" do
    test "filters.ex has no rescue _error or rescue _ clauses" do
      source = File.read!("lib/bds/rendering/filters.ex")
      refute source =~ ~r/rescue\s+_\w*\s*->/, "Found broad rescue clause in filters.ex"
    end

    test "filters.ex does not call read_template_file (which raises)" do
      source = File.read!("lib/bds/rendering/filters.ex")

      refute source =~ "read_template_file",
             "render_macro_template should use try_read, not read_template_file"
    end

    test "filters.ex uses FileSystem.try_read for macro templates" do
      source = File.read!("lib/bds/rendering/filters.ex")
      assert source =~ "FileSystem.try_read"
    end
  end
end
