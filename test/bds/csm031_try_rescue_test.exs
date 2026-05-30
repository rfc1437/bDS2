defmodule BDS.CSM031TryRescueTest do
  use ExUnit.Case, async: true

  describe "source-level: no inline try/rescue around Liquex.render!" do
    test "filters.ex has no try/rescue block in render_macro_source" do
      source = File.read!("lib/bds/rendering/filters.ex")

      refute source =~ ~r/try do\s+.*Liquex\.render!/s,
             "render_macro_source should use safe_liquex_render helper, not inline try/rescue"
    end

    test "filters.ex isolates Liquex.render! rescue in safe_liquex_render" do
      source = File.read!("lib/bds/rendering/filters.ex")
      assert source =~ "defp safe_liquex_render"
    end

    test "template_selection.ex has no try/rescue block in render_template" do
      source = File.read!("lib/bds/rendering/template_selection.ex")
      lines = String.split(source, "\n")

      in_render_template =
        lines
        |> Enum.drop_while(&(not String.contains?(&1, "def render_template(")))
        |> Enum.take_while(&(not String.match?(&1, ~r/^\s+def[p]?\s/)))

      body = Enum.join(in_render_template, "\n")
      refute body =~ "try do", "render_template should not contain inline try/rescue"
    end

    test "template_selection.ex isolates Liquex.render! rescue in safe_liquex_render" do
      source = File.read!("lib/bds/rendering/template_selection.ex")
      assert source =~ "defp safe_liquex_render"
    end
  end

  describe "source-level: no function-level rescue in load_bundled_template_source" do
    test "template_selection.ex load_bundled_template_source has no rescue block" do
      source = File.read!("lib/bds/rendering/template_selection.ex")
      lines = String.split(source, "\n")

      in_load_bundled =
        lines
        |> Enum.drop_while(&(not String.contains?(&1, "defp load_bundled_template_source(")))
        |> Enum.take_while(fn line ->
          not (String.match?(line, ~r/^\s+def[p]?\s/) and
                 not String.contains?(line, "load_bundled_template_source"))
        end)

      body = Enum.join(in_load_bundled, "\n")
      refute body =~ ~r/^\s+rescue\b/m, "load_bundled_template_source should use with, not rescue"
    end

    test "template_selection.ex uses FileSystem.try_read instead of read_template_file" do
      source = File.read!("lib/bds/rendering/template_selection.ex")

      refute source =~ "read_template_file",
             "should use FileSystem.try_read, not the raising read_template_file"

      assert source =~ "FileSystem.try_read"
    end
  end

  describe "source-level: shell_data.ex has no try/rescue" do
    test "shell_data.ex contains no try/rescue blocks" do
      source = File.read!("lib/bds/desktop/shell_data.ex")
      refute source =~ ~r/\btry\s+do\b/, "shell_data.ex should not contain try/rescue blocks"
      refute source =~ ~r/\brescue\b/, "shell_data.ex should not contain rescue clauses"
    end
  end
end
