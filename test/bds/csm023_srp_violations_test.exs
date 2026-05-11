defmodule BDS.CSM023SrpViolationsTest do
  use ExUnit.Case, async: true

  describe "Templates.do_update_template/2 decomposition" do
    test "update_template pipeline is decomposed into focused private functions" do
      source = File.read!("lib/bds/templates.ex")

      assert source =~ "defp resolve_next_slug("
      assert source =~ "defp content_changed?("
      assert source =~ "defp resolve_next_status("
      assert source =~ "defp build_update_attrs("
      assert source =~ "defp commit_update_transaction("

      refute source =~ "defp do_update_template(template, attrs) do\n    next_slug =",
             "do_update_template should delegate to focused helpers, not inline all logic"
    end

    test "do_update_template delegates to helpers instead of inlining" do
      source = File.read!("lib/bds/templates.ex")

      [do_update_body] =
        Regex.scan(
          ~r/defp do_update_template\(template, attrs\) do\n(.*?)(?=\n  defp )/s,
          source,
          capture: :all_but_first
        )
        |> Enum.map(&hd/1)

      assert do_update_body =~ "resolve_next_slug(template, attrs)"
      assert do_update_body =~ "content_changed?(template, attrs)"
      assert do_update_body =~ "resolve_next_status(template, content_changed?)"
      assert do_update_body =~ "build_update_attrs(template, attrs, next_slug, next_status, now)"
      assert do_update_body =~ "commit_update_transaction(template, updates, slug_changed?, now)"
    end
  end

  describe "Capabilities.for_project/2 decomposition" do
    test "for_project delegates to domain-specific builder functions" do
      source = File.read!("lib/bds/scripting/capabilities.ex")

      assert source =~ "defp app_capabilities("
      assert source =~ "defp project_capabilities("
      assert source =~ "defp meta_capabilities("
      assert source =~ "defp post_capabilities("
      assert source =~ "defp media_capabilities("
      assert source =~ "defp script_capabilities("
      assert source =~ "defp template_capabilities("
      assert source =~ "defp tag_capabilities("
      assert source =~ "defp task_capabilities"
      assert source =~ "defp sync_capabilities("
      assert source =~ "defp publish_capabilities("
      assert source =~ "defp chat_capabilities("
      assert source =~ "defp embedding_capabilities("
    end

    test "for_project body is a concise map of builder calls" do
      source = File.read!("lib/bds/scripting/capabilities.ex")
      for_project_body = extract_for_project_body(source)

      line_count = for_project_body |> String.split("\n") |> length()

      assert line_count <= 20,
             "for_project body should be a concise dispatch map, got #{line_count} lines"
    end

    test "no domain-specific capability entries remain in for_project body" do
      source = File.read!("lib/bds/scripting/capabilities.ex")
      for_project_body = extract_for_project_body(source)

      refute for_project_body =~ "one_arg(",
             "for_project body should not contain one_arg calls directly"

      refute for_project_body =~ "zero_or_one_arg(",
             "for_project body should not contain zero_or_one_arg calls directly"
    end

    defp extract_for_project_body(source) do
      lines = String.split(source, "\n")
      start_idx = Enum.find_index(lines, &String.contains?(&1, "def for_project("))
      remaining = Enum.drop(lines, start_idx + 1)
      end_idx = Enum.find_index(remaining, &(&1 == "  end"))
      remaining |> Enum.take(end_idx) |> Enum.join("\n")
    end
  end
end
