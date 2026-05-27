defmodule BDS.CSM032MapGetPatternMatchTest do
  use ExUnit.Case, async: true

  @metadata_consumers [
    "lib/bds/posts/translation_validation.ex",
    "lib/bds/posts/auto_translation.ex",
    "lib/bds/desktop/shell_commands.ex",
    "lib/bds/desktop/shell_live/settings_editor/project_settings.ex",
    "lib/bds/desktop/shell_live/settings_editor/style_editor.ex",
    "lib/bds/desktop/shell_live/settings_editor/managed_categories.ex",
    "lib/bds/desktop/shell_live/settings_editor/publishing_settings.ex",
    "lib/bds/desktop/shell_live/import_editor/taxonomy_editing.ex",
    "lib/bds/desktop/shell_live/import_editor/analysis_state.ex",
    "lib/bds/import_execution.ex"
  ]

  @metadata_atom_keys ~w(main_language blog_languages categories category_settings
                         publishing_preferences name description public_url default_author
                         max_posts_per_page blogmark_category pico_theme
                         semantic_similarity_enabled)

  describe "source-level: no Map.get(metadata, :atom_key) on metadata struct" do
    for file <- @metadata_consumers do
      test "#{Path.basename(file)} uses dot access instead of Map.get for metadata atom keys" do
        source = File.read!(unquote(file))

        for key <- @metadata_atom_keys do
          refute source =~ "Map.get(metadata, :#{key}",
                 "#{unquote(file)} should use metadata.#{key} instead of Map.get(metadata, :#{key})"
        end
      end
    end
  end

  describe "source-level: overlay.ex uses pattern matching for known structures" do
    test "delete_details uses pattern matching instead of Map.get" do
      source = File.read!("lib/bds/desktop/overlay.ex")
      refute source =~ "Map.get(delete_details,",
             "overlay.ex should pattern match delete_details instead of using Map.get"
    end

    test "merge_details uses pattern matching instead of Map.get" do
      source = File.read!("lib/bds/desktop/overlay.ex")
      refute source =~ "Map.get(merge,",
             "overlay.ex should pattern match merge_details instead of using Map.get"
    end

    test "media struct fields use dot access in to_insert_media_result" do
      source = File.read!("lib/bds/desktop/overlay.ex")

      refute source =~ ~r/to_insert_media_result.*Map\.get\(media/s &&
               source =~ "defp to_insert_media_result",
             "to_insert_media_result should use dot access for media fields"
    end

    test "media struct fields use dot access in to_gallery_image" do
      source = File.read!("lib/bds/desktop/overlay.ex")

      refute source =~ ~r/to_gallery_image.*Map\.get\(media/s &&
               source =~ "defp to_gallery_image",
             "to_gallery_image should use dot access for media fields"
    end
  end

  describe "source-level: generation pipeline uses dot access for Post struct fields" do
    test "outputs.ex uses post.language instead of Map.get(post, :language)" do
      source = File.read!("lib/bds/generation/outputs.ex")
      refute source =~ "Map.get(post, :language)",
             "outputs.ex should use post.language"
    end

    test "data.ex uses dot access for Post struct fields in build_published_translation_variant" do
      source = File.read!("lib/bds/generation/data.ex")
      refute source =~ "Map.get(post, :author)",
             "data.ex should use post.author"
      refute source =~ "Map.get(post, :tags",
             "data.ex should use post.tags"
      refute source =~ "Map.get(post, :categories",
             "data.ex should use post.categories"
      refute source =~ "Map.get(post, :template_slug)",
             "data.ex should use post.template_slug"
      refute source =~ "Map.get(post, :do_not_translate",
             "data.ex should use post.do_not_translate"
    end

    test "validation.ex uses post.file_path instead of Map.get(post, :file_path)" do
      source = File.read!("lib/bds/generation/validation.ex")
      refute source =~ "Map.get(post, :file_path)",
             "validation.ex should use post.file_path"
    end

    test "sitemap.ex uses post.do_not_translate instead of Map.get" do
      source = File.read!("lib/bds/generation/sitemap.ex")
      refute source =~ "Map.get(post, :do_not_translate)",
             "sitemap.ex should use post.do_not_translate"
    end
  end
end
