defmodule BDS.BoundedAtomsTest do
  use ExUnit.Case, async: true

  alias BDS.BoundedAtoms

  test "parses only explicit atoms from each bounded domain" do
    assert BoundedAtoms.sidebar_view("posts") == :posts
    assert BoundedAtoms.editor_route("metadata_diff") == :metadata_diff
    assert BoundedAtoms.panel_tab("post_links") == :post_links
    assert BoundedAtoms.post_status("archived") == :archived
    assert BoundedAtoms.translation_status("published") == :published
    assert BoundedAtoms.script_kind("transform") == :transform
    assert BoundedAtoms.template_kind("not_found") == :not_found
    assert BoundedAtoms.menu_kind("category-archive") == :category_archive
    assert BoundedAtoms.import_section("taxonomy") == :taxonomy
    assert BoundedAtoms.taxonomy_type("tags") == :tags
    assert BoundedAtoms.ai_endpoint("airplane") == :airplane
    assert BoundedAtoms.mcp_agent("github_copilot") == :github_copilot
    assert BoundedAtoms.shell_command("toggle_panel") == :toggle_panel
  end

  test "falls back without creating atoms for unknown strings" do
    assert BoundedAtoms.sidebar_view("unknown", :posts) == :posts
    assert BoundedAtoms.editor_route("unknown", :dashboard) == :dashboard
    assert BoundedAtoms.panel_tab("unknown", :tasks) == :tasks
    assert BoundedAtoms.post_status("unknown", :draft) == :draft
    assert BoundedAtoms.translation_status("unknown", :draft) == :draft
    assert BoundedAtoms.script_kind("unknown", :utility) == :utility
    assert BoundedAtoms.template_kind("unknown", :post) == :post
    assert BoundedAtoms.menu_kind("unknown", :page) == :page
    assert BoundedAtoms.import_section("unknown") == nil
    assert BoundedAtoms.taxonomy_type("unknown") == nil
    assert BoundedAtoms.ai_endpoint("unknown") == nil
    assert BoundedAtoms.mcp_agent("unknown") == nil
    assert BoundedAtoms.shell_command("unknown") == nil
  end

  test "codebase does not use String.to_existing_atom rescues" do
    lib_dir = Path.expand("../../lib", __DIR__)

    offenders =
      lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "bounded_atoms.ex"))
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.contains?("String.to_existing_atom")
      end)

    assert offenders == []
  end
end
