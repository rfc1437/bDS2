defmodule BDS.CSM029LengthInGuardsTest do
  use ExUnit.Case, async: true

  @outputs_path "lib/bds/generation/outputs.ex"
  @sidebar_path "lib/bds/ui/sidebar.ex"

  describe "source-level: length/1 bound before use in loops" do
    test "outputs.ex route path functions bind length before passing to paginated_archive_paths" do
      source = File.read!(@outputs_path)

      refute source =~ ~r/paginated_archive_paths\([^)]*length\(posts\)/,
             "length(posts) should be bound to a variable before passing to paginated_archive_paths"
    end

    test "sidebar.ex build_post_section binds length before map literal" do
      source = File.read!(@sidebar_path)

      lines =
        source
        |> String.split("\n")
        |> Enum.with_index(1)

      build_section_lines =
        Enum.filter(lines, fn {line, _} -> line =~ "defp build_post_section" end)

      for {_line, line_no} <- build_section_lines do
        context =
          lines
          |> Enum.drop(line_no - 1)
          |> Enum.take(30)
          |> Enum.map(fn {l, _} -> l end)
          |> Enum.join("\n")

        refute context =~ ~r/count: length\(/,
               "length() should be pre-bound, not inline in map literal"
      end
    end

    test "no length/1 calls remain inline inside Enum.flat_map callbacks in route path functions" do
      source = File.read!(@outputs_path)

      route_fns = ["category_route_paths", "tag_route_paths", "date_route_paths"]

      for fn_name <- route_fns do
        fn_match = Regex.run(~r/def #{fn_name}\(.*?\n  end/s, source)
        assert fn_match, "Expected to find #{fn_name} in outputs.ex"

        [fn_body] = fn_match

        refute fn_body =~ ~r/\blength\(posts\)(?!\s)/,
               "#{fn_name} should use pre-bound post_count instead of inline length(posts)"
      end
    end
  end
end
