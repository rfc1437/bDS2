defmodule BDS.PostTranslationsTest do
  use ExUnit.Case, async: false

  alias BDS.Metadata
  alias BDS.Posts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-post-translations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Translations", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "upserted post translations publish with the canonical post, reopen on edit, and delete their file", %{project: project, temp_dir: temp_dir} do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Canonical Post",
               excerpt: "English summary",
               content: "Hello world",
               language: "en"
             })

    assert {:ok, translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Kanonischer Beitrag",
               excerpt: "Deutsche Zusammenfassung",
               content: "Hallo Welt"
             })

    assert translation.translation_for == post.id
    assert translation.language == "de"
    assert translation.status == :draft
    assert translation.file_path == ""
    assert translation.content == "Hallo Welt"

    assert {:ok, [listed_translation]} = Posts.list_post_translations(post.id)
    assert listed_translation.id == translation.id

    assert {:ok, _published_post} = Posts.publish_post(post.id)
    assert published_translation = Posts.get_post_translation!(translation.id)

    assert published_translation.status == :published
    assert is_integer(published_translation.published_at)
    assert published_translation.content == nil
    assert published_translation.file_path =~ ~r/^posts\/\d{4}\/\d{2}\/canonical-post\.de\.md$/

    translation_path = Path.join(temp_dir, published_translation.file_path)
    assert File.exists?(translation_path)

    translation_contents = File.read!(translation_path)
    assert translation_contents =~ "title: Kanonischer Beitrag\n"
    assert translation_contents =~ "language: de\n"
    assert translation_contents =~ "status: published\n"
    assert translation_contents =~ "\n---\nHallo Welt\n"

    assert {:ok, reopened_translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Neu formuliert",
               excerpt: "Aktualisiert",
               content: "Neuer Entwurf"
             })

    assert reopened_translation.status == :draft
    assert reopened_translation.title == "Neu formuliert"
    assert reopened_translation.excerpt == "Aktualisiert"
    assert reopened_translation.content == "Neuer Entwurf"
    assert reopened_translation.updated_at >= published_translation.updated_at

    assert {:ok, :deleted} = Posts.delete_post_translation(reopened_translation.id)
    refute File.exists?(translation_path)
    assert {:ok, []} = Posts.list_post_translations(post.id)
  end

  test "validate_translations reports missing languages, orphan translation files, and do-not-translate posts", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de", "fr"]
             })

    assert {:ok, translatable_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Needs French",
               content: "Body",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(translatable_post.id, "de", %{
               title: "Braucht Französisch",
               content: "Inhalt"
             })

    assert {:ok, _published} = Posts.publish_post(translatable_post.id)

    assert {:ok, ignored_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Skip Me",
               content: "Body",
               language: "en"
             })

    assert {:ok, ignored_post} = Posts.update_post(ignored_post.id, %{do_not_translate: true})
    assert {:ok, _published_ignored_post} = Posts.publish_post(ignored_post.id)

    orphan_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(orphan_dir)

    orphan_path = Path.join(orphan_dir, "orphan.fr.md")

    File.write!(
      orphan_path,
      [
        "---",
        "id: orphan-translation",
        "translation_for: missing-post",
        "language: fr",
        "title: Orpheline",
        "status: published",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "published_at: 1712016000",
        "---",
        "Texte orphelin",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, report} = Posts.validate_translations(project.id)

    assert report.missing == [%{post_id: translatable_post.id, language: "fr"}]
    assert report.orphan_files == ["posts/2026/04/orphan.fr.md"]
    assert report.do_not_translate_posts == [ignored_post.id]
  end
end
