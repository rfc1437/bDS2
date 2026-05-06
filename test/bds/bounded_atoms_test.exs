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

  test "accepts implemented blog menu shell commands" do
    commands = [
      {"preview_post", :preview_post},
      {"rebuild_database", :rebuild_database},
      {"reindex_text", :reindex_text},
      {"rebuild_embedding_index", :rebuild_embedding_index},
      {"metadata_diff", :metadata_diff},
      {"validate_translations", :validate_translations},
      {"fill_missing_translations", :fill_missing_translations},
      {"find_duplicates", :find_duplicates},
      {"generate_sitemap", :generate_sitemap},
      {"validate_site", :validate_site},
      {"upload_site", :upload_site}
    ]

    for {value, expected} <- commands do
      assert BoundedAtoms.shell_command(value) == expected
    end
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

  test "codebase does not use String.to_atom on dynamic data" do
    lib_dir = Path.expand("../../lib", __DIR__)

    allowed_files = [
      "bounded_atoms.ex",
      "map_utils.ex"
    ]

    offenders =
      lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        Enum.any?(allowed_files, &String.ends_with?(path, &1))
      end)
      |> Enum.filter(fn path ->
        content = File.read!(path)
        String.contains?(content, "String.to_atom(")
      end)
      |> Enum.map(&Path.relative_to(&1, lib_dir))

    assert offenders == [],
           "Files still using String.to_atom (use String.to_existing_atom or BDS.MapUtils.safe_atomize_key): #{Enum.join(offenders, ", ")}"
  end
end
