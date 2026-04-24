defmodule BDS.MaintenanceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-maintenance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Maintenance", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "rebuild_from_filesystem dispatches to posts, media, scripts, and templates rebuilders", %{
    project: project,
    temp_dir: temp_dir
  } do
    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "dispatch-post.md"),
      [
        "---",
        "id: dispatch-post",
        "title: Dispatch Post",
        "slug: dispatch-post",
        "status: published",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "published_at: 1712016000",
        "tags:",
        "categories:",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "asset.txt"), "hello media")

    File.write!(
      Path.join(media_dir, "asset.txt.meta"),
      [
        "id: dispatch-media",
        "original_name: original.txt",
        "mime_type: text/plain",
        "size: 11",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "tags:",
        ""
      ]
      |> Enum.join("\n")
    )

    template_dir = Path.join(temp_dir, "templates")
    File.mkdir_p!(template_dir)

    File.write!(
      Path.join(template_dir, "dispatch-view.liquid"),
      [
        "---",
        "id: dispatch-template",
        "slug: dispatch-view",
        "title: Dispatch View",
        "kind: list",
        "enabled: true",
        "version: 1",
        "created_at: 101",
        "updated_at: 202",
        "---",
        "<section>Template</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    script_dir = Path.join(temp_dir, "scripts")
    File.mkdir_p!(script_dir)

    File.write!(
      Path.join(script_dir, "dispatch.lua"),
      [
        "---",
        "id: dispatch-script",
        "slug: dispatch",
        "title: Dispatch Script",
        "kind: utility",
        "entrypoint: main",
        "enabled: true",
        "version: 1",
        "created_at: 301",
        "updated_at: 404",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
    assert length(posts) == 1

    assert {:ok, media_items} = BDS.Maintenance.rebuild_from_filesystem(project.id, "media")
    assert length(media_items) == 1

    assert {:ok, scripts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "script")
    assert length(scripts) == 1

    assert {:ok, templates} = BDS.Maintenance.rebuild_from_filesystem(project.id, "template")
    assert length(templates) == 4

    assert Repo.get(BDS.Posts.Post, "dispatch-post") != nil
    assert Repo.get(BDS.Media.Media, "dispatch-media") != nil
    assert Repo.get(BDS.Scripts.Script, "dispatch-script") != nil
    assert Repo.get(BDS.Templates.Template, "dispatch-template") != nil
  end

  test "rebuild_from_filesystem rejects unsupported entity types", %{project: project} do
    assert {:error, :unsupported_entity_type} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "unknown")
  end

  test "metadata_diff reports field differences and orphan files across managed entities", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Original Post",
               content: "Original body",
               excerpt: "Original summary",
               author: "Writer",
               language: "en",
               tags: ["alpha"],
               categories: ["notes"]
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, post_translation} =
             BDS.Posts.upsert_post_translation(published_post.id, "de", %{
               title: "Ursprunglicher Beitrag",
               excerpt: "Zusammenfassung",
               content: "Ubersetzter Inhalt"
             })

    assert {:ok, _republished_post} = BDS.Posts.publish_post(published_post.id)
    published_post_translation = Repo.get!(BDS.Posts.Translation, post_translation.id)

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Original media title",
               alt: "Original alt",
               caption: "Original caption",
               author: "Photographer",
               language: "en",
               tags: ["alpha"]
             })

    assert {:ok, media_translation} =
             BDS.Media.upsert_media_translation(media.id, "de", %{
               title: "Ubersetzter Medientitel",
               alt: "Ubersetzter Alt-Text",
               caption: "Ubersetzte Beschriftung"
             })

    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Original Script",
               kind: :utility,
               entrypoint: "main",
               content: "function main() return true end"
             })

    assert {:ok, published_script} = BDS.Scripts.publish_script(script.id)

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Original Template",
               kind: :list,
               content: "<section>Original</section>"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    post_path = Path.join(temp_dir, published_post.file_path)

    File.write!(
      post_path,
      [
        "---",
        "id: #{published_post.id}",
        "title: Edited Post",
        "slug: #{published_post.slug}",
        "excerpt: Edited summary",
        "status: published",
        "author: Editor",
        "language: de",
        "do_not_translate: false",
        "template_slug: ",
        "created_at: #{published_post.created_at + 10}",
        "updated_at: #{published_post.updated_at + 20}",
        "published_at: #{published_post.published_at + 30}",
        "tags:",
        "  - beta",
        "categories:",
        "  - article",
        "---",
        "Changed body",
        ""
      ]
      |> Enum.join("\n")
    )

    post_translation_path = Path.join(temp_dir, published_post_translation.file_path)

    File.write!(
      post_translation_path,
      [
        "---",
        "id: #{published_post_translation.id}",
        "translation_for: #{published_post_translation.translation_for}",
        "language: #{published_post_translation.language}",
        "title: Bearbeiteter Beitrag",
        "excerpt: Bearbeitete Zusammenfassung",
        "status: published",
        "created_at: #{published_post_translation.created_at}",
        "updated_at: #{published_post_translation.updated_at}",
        "published_at: #{published_post_translation.published_at}",
        "---",
        "Bearbeiteter Inhalt",
        ""
      ]
      |> Enum.join("\n")
    )

    media_sidecar_path = Path.join(temp_dir, media.sidecar_path)

    File.write!(
      media_sidecar_path,
      [
        "id: #{media.id}",
        "original_name: #{media.original_name}",
        "mime_type: #{media.mime_type}",
        "size: #{media.size}",
        "title: Edited media title",
        "alt: Edited alt",
        "caption: Edited caption",
        "author: Editor",
        "language: de",
        "created_at: #{media.created_at}",
        "updated_at: #{media.updated_at}",
        "tags:",
        "  - beta",
        ""
      ]
      |> Enum.join("\n")
    )

    media_translation_sidecar_path =
      Path.join(temp_dir, "#{media.file_path}.#{media_translation.language}.meta")

    File.write!(
      media_translation_sidecar_path,
      [
        "translation_for: #{media.id}",
        "language: #{media_translation.language}",
        "title: Bearbeiteter Medientitel",
        "alt: Bearbeiteter Alt-Text",
        "caption: Bearbeitete Beschriftung",
        ""
      ]
      |> Enum.join("\n")
    )

    script_path = Path.join(temp_dir, published_script.file_path)

    File.write!(
      script_path,
      [
        "---",
        "id: #{published_script.id}",
        "slug: #{published_script.slug}",
        "title: Edited Script",
        "kind: utility",
        "entrypoint: run",
        "enabled: false",
        "version: #{published_script.version}",
        "created_at: #{published_script.created_at}",
        "updated_at: #{published_script.updated_at}",
        "---",
        "function run() return false end",
        ""
      ]
      |> Enum.join("\n")
    )

    template_path = Path.join(temp_dir, published_template.file_path)

    File.write!(
      template_path,
      [
        "---",
        "id: #{published_template.id}",
        "slug: #{published_template.slug}",
        "title: Edited Template",
        "kind: list",
        "enabled: false",
        "version: #{published_template.version}",
        "created_at: #{published_template.created_at}",
        "updated_at: #{published_template.updated_at}",
        "---",
        "<section>Edited</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join([temp_dir, "posts", "2026", "04", "orphan-post.md"]),
      "---\nid: orphan\ntitle: Orphan\nslug: orphan\nstatus: published\ncreated_at: 1\nupdated_at: 1\npublished_at: 1\ntags:\ncategories:\n---\nBody\n"
    )

    File.write!(
      Path.join([temp_dir, "posts", "2026", "04", "orphan-post.es.md"]),
      "---\nid: orphan-post-translation\ntranslation_for: orphan\nlanguage: es\ntitle: Huerfano\nstatus: published\ncreated_at: 1\nupdated_at: 1\npublished_at: 1\n---\nCuerpo\n"
    )

    File.write!(Path.join([temp_dir, "media", "2026", "04", "orphan.txt"]), "orphan")

    File.write!(
      Path.join([temp_dir, "media", "2026", "04", "orphan.txt.meta"]),
      "id: orphan-media\noriginal_name: orphan.txt\nmime_type: text/plain\nsize: 6\ncreated_at: 1\nupdated_at: 1\ntags:\n"
    )

    File.write!(
      Path.join([temp_dir, "media", "2026", "04", "orphan.txt.es.meta"]),
      "translation_for: orphan-media\nlanguage: es\ntitle: Huerfano\nalt: Texto\ncaption: Leyenda\n"
    )

    File.write!(
      Path.join([temp_dir, "scripts", "orphan.lua"]),
      "---\nid: orphan-script\nslug: orphan-script\ntitle: Orphan Script\nkind: utility\nentrypoint: main\nenabled: true\nversion: 1\ncreated_at: 1\nupdated_at: 1\n---\nfunction main() return true end\n"
    )

    File.write!(
      Path.join([temp_dir, "templates", "orphan-view.liquid"]),
      "---\nid: orphan-template\nslug: orphan-view\ntitle: Orphan View\nkind: list\nenabled: true\nversion: 1\ncreated_at: 1\nupdated_at: 1\n---\n<section>Orphan</section>\n"
    )

    assert {:ok, %{diff_reports: diff_reports, orphan_reports: orphan_reports}} =
             BDS.Maintenance.metadata_diff(project.id)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "post" and report.entity_id == published_post.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.db_value == "Original Post" and
                     &1.file_value == "Edited Post")
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "excerpt" and &1.db_value == "Original summary" and
                     &1.file_value == "Edited summary")
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "created_at" and
                     &1.file_value == Integer.to_string(published_post.created_at + 10))
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "updated_at" and
                     &1.file_value == Integer.to_string(published_post.updated_at + 20))
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "published_at" and
                     &1.file_value == Integer.to_string(published_post.published_at + 30))
               )
           end)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "media" and report.entity_id == media.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.file_value == "Edited media title")
               ) and
               Enum.any?(report.differences, &(&1.name == "language" and &1.file_value == "de"))
           end)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "script" and report.entity_id == published_script.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.file_value == "Edited Script")
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "entrypoint" and &1.file_value == "run")
               )
           end)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "template" and report.entity_id == published_template.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.file_value == "Edited Template")
               ) and
               Enum.any?(report.differences, &(&1.name == "enabled" and &1.file_value == "false"))
           end)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "post_translation" and
               report.entity_id == published_post_translation.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.db_value == "Ursprunglicher Beitrag" and
                     &1.file_value == "Bearbeiteter Beitrag")
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "excerpt" and &1.db_value == "Zusammenfassung" and
                     &1.file_value == "Bearbeitete Zusammenfassung")
               )
           end)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "media_translation" and
               report.entity_id == media_translation.id and
               Enum.any?(
                 report.differences,
                 &(&1.name == "title" and &1.db_value == "Ubersetzter Medientitel" and
                     &1.file_value == "Bearbeiteter Medientitel")
               ) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "alt" and &1.db_value == "Ubersetzter Alt-Text" and
                     &1.file_value == "Bearbeiteter Alt-Text")
               )
           end)

    orphan_paths = Enum.map(orphan_reports, & &1.file_path)
    assert "posts/2026/04/orphan-post.md" in orphan_paths
    assert "posts/2026/04/orphan-post.es.md" in orphan_paths
    assert "media/2026/04/orphan.txt.meta" in orphan_paths
    assert "media/2026/04/orphan.txt.es.meta" in orphan_paths
    assert "scripts/orphan.lua" in orphan_paths
    assert "templates/orphan-view.liquid" in orphan_paths
  end
end
