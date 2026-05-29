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
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

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
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "publishedAt: 1712016000",
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
        "originalName: original.txt",
        "mimeType: text/plain",
        "size: 11",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
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
        "createdAt: 101",
        "updatedAt: 202",
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
        "createdAt: 301",
        "updatedAt: 404",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
    assert length(posts) == 1

    assert Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: "dispatch-post") !=
             nil

    assert {:ok, media_items} = BDS.Maintenance.rebuild_from_filesystem(project.id, "media")
    assert length(media_items) == 1

    assert {:ok, scripts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "script")
    assert length(scripts) == 1

    assert {:ok, templates} = BDS.Maintenance.rebuild_from_filesystem(project.id, "template")
    assert length(templates) == 1

    assert Repo.get(BDS.Posts.Post, "dispatch-post") != nil
    assert Repo.get(BDS.Media.Media, "dispatch-media") != nil
    assert Repo.get(BDS.Scripts.Script, "dispatch-script") != nil
    assert Repo.get(BDS.Templates.Template, "dispatch-template") != nil
  end

  test "rebuild_from_filesystem rejects unsupported entity types", %{project: project} do
    assert {:error, :unsupported_entity_type} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "unknown")
  end

  test "rebuild_from_filesystem reports incremental progress for file-backed rebuilders", %{
    project: project,
    temp_dir: temp_dir
  } do
    parent = self()
    on_progress = fn value, message -> send(parent, {:rebuild_progress, value, message}) end

    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "first-post.md"),
      [
        "---",
        "id: first-post",
        "title: First Post",
        "slug: first-post",
        "status: published",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "publishedAt: 1712016000",
        "tags:",
        "categories:",
        "---",
        "Body one",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(posts_dir, "second-post.md"),
      [
        "---",
        "id: second-post",
        "title: Second Post",
        "slug: second-post",
        "status: published",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "publishedAt: 1712016000",
        "tags:",
        "categories:",
        "---",
        "Body two",
        ""
      ]
      |> Enum.join("\n")
    )

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    File.write!(Path.join(media_dir, "first.txt"), "first media")
    File.write!(Path.join(media_dir, "second.txt"), "second media")

    File.write!(
      Path.join(media_dir, "first.txt.meta"),
      [
        "id: first-media",
        "originalName: first.txt",
        "mimeType: text/plain",
        "size: 11",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "tags:",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(media_dir, "second.txt.meta"),
      [
        "id: second-media",
        "originalName: second.txt",
        "mimeType: text/plain",
        "size: 12",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "tags:",
        ""
      ]
      |> Enum.join("\n")
    )

    template_dir = Path.join(temp_dir, "templates")
    File.mkdir_p!(template_dir)

    File.write!(
      Path.join(template_dir, "first-template.liquid"),
      [
        "---",
        "id: first-template",
        "slug: first-template",
        "title: First Template",
        "kind: list",
        "enabled: true",
        "version: 1",
        "createdAt: 101",
        "updatedAt: 202",
        "---",
        "<section>First</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(template_dir, "second-template.liquid"),
      [
        "---",
        "id: second-template",
        "slug: second-template",
        "title: Second Template",
        "kind: post",
        "enabled: true",
        "version: 1",
        "createdAt: 303",
        "updatedAt: 404",
        "---",
        "<section>Second</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    script_dir = Path.join(temp_dir, "scripts")
    File.mkdir_p!(script_dir)

    File.write!(
      Path.join(script_dir, "first-script.lua"),
      [
        "---",
        "id: first-script",
        "slug: first-script",
        "title: First Script",
        "kind: utility",
        "entrypoint: main",
        "enabled: true",
        "version: 1",
        "createdAt: 505",
        "updatedAt: 606",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(script_dir, "second-script.lua"),
      [
        "---",
        "id: second-script",
        "slug: second-script",
        "title: Second Script",
        "kind: transform",
        "entrypoint: main",
        "enabled: true",
        "version: 1",
        "createdAt: 707",
        "updatedAt: 808",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, _posts} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "post", on_progress: on_progress)

    assert_incremental_progress(collect_progress_events())

    assert {:ok, _media} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "media",
               on_progress: on_progress
             )

    assert_incremental_progress(collect_progress_events())

    assert {:ok, _scripts} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "script",
               on_progress: on_progress
             )

    assert_incremental_progress(collect_progress_events())

    assert {:ok, _templates} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "template",
               on_progress: on_progress
             )

    assert_incremental_progress(collect_progress_events())
  end

  test "metadata_diff reports incremental progress across comparison phases", %{
    project: project,
    temp_dir: temp_dir
  } do
    parent = self()
    on_progress = fn value, message -> send(parent, {:rebuild_progress, value, message}) end

    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    Enum.each(1..40, fn index ->
      slug = "diff-progress-post-#{index}"

      File.write!(
        Path.join(posts_dir, "#{slug}.md"),
        [
          "---",
          "id: #{slug}",
          "title: Diff Progress Post #{index}",
          "slug: #{slug}",
          "status: published",
          "createdAt: 1711843200",
          "updatedAt: 1711929600",
          "publishedAt: 1712016000",
          "tags:",
          "categories:",
          "---",
          "Body #{index}",
          ""
        ]
        |> Enum.join("\n")
      )
    end)

    assert {:ok, _posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")

    assert {:ok, _diff} = BDS.Maintenance.metadata_diff(project.id, on_progress: on_progress)

    events = collect_progress_events()
    assert_incremental_progress(events)
    assert Enum.any?(events, fn {_value, message} -> String.contains?(message, "Comparing") end)
  end

  test "maintenance rebuilds and diffs embedding state explicitly", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Embedding Drift",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    index_path = BDS.Embeddings.index_path(project.id)
    # Index persistence is debounced (5s); force it to assert the file.
    :ok = BDS.Embeddings.Index.flush(project.id)
    assert File.exists?(index_path)

    Repo.delete_all(from key in BDS.Embeddings.Key, where: key.project_id == ^project.id)

    assert {:ok, %{diff_reports: diff_reports}} = BDS.Maintenance.metadata_diff(project.id)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "embedding" and report.entity_id == post.id and
               Enum.any?(report.differences, &(&1.name == "content_hash" and &1.file_value != "")) and
               Enum.any?(
                 report.differences,
                 &(&1.name == "embedding" and &1.db_value == "missing" and
                     &1.file_value == "re-embed required")
               )
           end)

    assert {:ok, rebuilt_post_ids} =
             BDS.Maintenance.rebuild_from_filesystem(project.id, "embedding")

    assert post.id in rebuilt_post_ids
    assert Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: post.id) != nil

    :ok = BDS.Embeddings.Index.flush(project.id)
    assert File.exists?(index_path)
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
        "doNotTranslate: false",
        "templateSlug: ",
        "createdAt: #{published_post.created_at + 10}",
        "updatedAt: #{published_post.updated_at + 20}",
        "publishedAt: #{published_post.published_at + 30}",
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
        "translationFor: #{published_post_translation.translation_for}",
        "language: #{published_post_translation.language}",
        "title: Bearbeiteter Beitrag",
        "excerpt: Bearbeitete Zusammenfassung",
        "status: published",
        "createdAt: #{published_post_translation.created_at}",
        "updatedAt: #{published_post_translation.updated_at}",
        "publishedAt: #{published_post_translation.published_at}",
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
        "originalName: #{media.original_name}",
        "mimeType: #{media.mime_type}",
        "size: #{media.size}",
        "title: Edited media title",
        "alt: Edited alt",
        "caption: Edited caption",
        "author: Editor",
        "language: de",
        "createdAt: #{media.created_at}",
        "updatedAt: #{media.updated_at}",
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
        "translationFor: #{media.id}",
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
        "projectId: #{project.id}",
        "slug: #{published_script.slug}",
        "title: Edited Script",
        "kind: utility",
        "entrypoint: run",
        "enabled: false",
        "version: #{published_script.version}",
        "createdAt: #{published_script.created_at}",
        "updatedAt: #{published_script.updated_at}",
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
        "projectId: #{project.id}",
        "slug: #{published_template.slug}",
        "title: Edited Template",
        "kind: list",
        "enabled: false",
        "version: #{published_template.version}",
        "createdAt: #{published_template.created_at}",
        "updatedAt: #{published_template.updated_at}",
        "---",
        "<section>Edited</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    File.mkdir_p!(Path.join([temp_dir, "posts", "2026", "04"]))
    File.mkdir_p!(Path.join([temp_dir, "media", "2026", "04"]))

    File.write!(
      Path.join([temp_dir, "posts", "2026", "04", "orphan-post.md"]),
      "---\nid: orphan\ntitle: Orphan\nslug: orphan\nstatus: published\ncreatedAt: 1\nupdatedAt: 1\npublishedAt: 1\ntags:\ncategories:\n---\nBody\n"
    )

    File.write!(
      Path.join([temp_dir, "posts", "2026", "04", "orphan-post.es.md"]),
      "---\nid: orphan-post-translation\ntranslationFor: orphan\nlanguage: es\ntitle: Huerfano\nstatus: published\ncreatedAt: 1\nupdatedAt: 1\npublishedAt: 1\n---\nCuerpo\n"
    )

    File.write!(Path.join([temp_dir, "media", "2026", "04", "orphan.txt"]), "orphan")

    File.write!(
      Path.join([temp_dir, "media", "2026", "04", "orphan.txt.meta"]),
      "id: orphan-media\noriginalName: orphan.txt\nmimeType: text/plain\nsize: 6\ncreatedAt: 1\nupdatedAt: 1\ntags:\n"
    )

    File.write!(
      Path.join([temp_dir, "media", "2026", "04", "orphan.txt.es.meta"]),
      "translationFor: orphan-media\nlanguage: es\ntitle: Huerfano\nalt: Texto\ncaption: Leyenda\n"
    )

    File.write!(
      Path.join([temp_dir, "scripts", "orphan.lua"]),
      "---\nid: orphan-script\nprojectId: #{project.id}\nslug: orphan-script\ntitle: Orphan Script\nkind: utility\nentrypoint: main\nenabled: true\nversion: 1\ncreatedAt: 1\nupdatedAt: 1\n---\nfunction main() return true end\n"
    )

    File.write!(
      Path.join([temp_dir, "templates", "orphan-view.liquid"]),
      "---\nid: orphan-template\nprojectId: #{project.id}\nslug: orphan-view\ntitle: Orphan View\nkind: list\nenabled: true\nversion: 1\ncreatedAt: 1\nupdatedAt: 1\n---\n<section>Orphan</section>\n"
    )

    assert {:ok, %{diff_reports: diff_reports, orphan_reports: orphan_reports}} =
             BDS.Maintenance.metadata_diff(project.id)

    assert Enum.any?(diff_reports, fn report ->
             report.entity_type == "post" and report.entity_id == published_post.id and
               report.label == "Original Post" and
               report.meta_label ==
                 BDS.Persistence.timestamp_to_iso8601(published_post.created_at) and
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

  test "metadata_diff ignores tag and category order like old bDS", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Ordered Post",
               content: "Body",
               tags: ["alpha", "beta"],
               categories: ["article", "notes"]
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    post_path = Path.join(temp_dir, published_post.file_path)

    File.write!(
      post_path,
      [
        "---",
        "id: #{published_post.id}",
        "title: #{published_post.title}",
        "slug: #{published_post.slug}",
        "status: published",
        "createdAt: '#{BDS.Persistence.timestamp_to_iso8601(published_post.created_at)}'",
        "updatedAt: '#{BDS.Persistence.timestamp_to_iso8601(published_post.updated_at)}'",
        "publishedAt: '#{BDS.Persistence.timestamp_to_iso8601(published_post.published_at)}'",
        "tags:",
        "  - beta",
        "  - alpha",
        "categories:",
        "  - notes",
        "  - article",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, %{diff_reports: diff_reports}} = BDS.Maintenance.metadata_diff(project.id)

    refute Enum.any?(diff_reports, fn report ->
             report.entity_type == "post" and report.entity_id == published_post.id and
               Enum.any?(report.differences, &(&1.name in ["tags", "categories"]))
           end)
  end

  test "metadata_diff accepts legacy snake_case post frontmatter keys for status and timestamps",
       %{
         project: project,
         temp_dir: temp_dir
       } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Legacy Keys Post",
               content: "Body",
               language: "en"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    post_path = Path.join(temp_dir, published_post.file_path)

    File.write!(
      post_path,
      [
        "---",
        "id: #{published_post.id}",
        "title: #{published_post.title}",
        "slug: #{published_post.slug}",
        "status: published",
        "language: en",
        "created_at: #{published_post.created_at}",
        "updated_at: #{published_post.updated_at}",
        "published_at: #{published_post.published_at}",
        "tags:",
        "categories:",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, %{diff_reports: diff_reports}} = BDS.Maintenance.metadata_diff(project.id)

    refute Enum.any?(diff_reports, fn report ->
             report.entity_type == "post" and report.entity_id == published_post.id and
               Enum.any?(
                 report.differences,
                 &(&1.name in ["status", "created_at", "updated_at", "published_at"])
               )
           end)
  end

  test "metadata_diff treats translation status and timestamps as inherited from the canonical post" do
    legacy_dir =
      Path.join(
        System.tmp_dir!(),
        "bds-maintenance-legacy-translation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(legacy_dir)
    on_exit(fn -> File.rm_rf(legacy_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{
               name: "Legacy Translation Diff",
               data_path: legacy_dir
             })

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "chimera.md"),
      [
        "---",
        "id: post-from-old-app",
        "title: Chimera Source",
        "slug: chimera",
        "status: published",
        "language: de",
        "createdAt: 2024-03-30T21:20:00.000Z",
        "updatedAt: 2024-03-31T21:20:00.000Z",
        "publishedAt: 2024-04-01T21:20:00.000Z",
        "---",
        "Quelle",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(posts_dir, "chimera.en.md"),
      [
        "---",
        "id: translation-from-old-app",
        "translationFor: post-from-old-app",
        "language: en",
        "title: Chimera",
        "excerpt: Imported translation",
        "---",
        "Translated body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, _posts} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert {:ok, %{diff_reports: diff_reports}} = BDS.Maintenance.metadata_diff(project.id)

    refute Enum.any?(diff_reports, fn report ->
             report.entity_type == "post_translation" and
               Enum.any?(
                 report.differences,
                 &(&1.name in ["status", "created_at", "updated_at", "published_at"])
               )
           end)
  end

  test "metadata_diff includes project-level metadata drift", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               name: "Database Blog",
               description: "Database description",
               public_url: "https://database.example",
               main_language: "en",
               default_author: "Database Author",
               max_posts_per_page: 25,
               blogmark_category: "article",
               pico_theme: "blue",
               semantic_similarity_enabled: false,
               blog_languages: ["de"]
             })

    assert {:ok, _metadata} =
             BDS.Metadata.set_publishing_preferences(project.id, %{
               ssh_host: "db.example",
               ssh_user: "db-user",
               ssh_remote_path: "/srv/db",
               ssh_mode: "scp"
             })

    meta_dir = Path.join(temp_dir, "meta")

    File.write!(
      Path.join(meta_dir, "project.json"),
      Jason.encode!(%{
        "name" => "Filesystem Blog",
        "description" => "Filesystem description",
        "publicUrl" => "https://filesystem.example",
        "mainLanguage" => "fr",
        "defaultAuthor" => "Filesystem Author",
        "maxPostsPerPage" => 12,
        "blogmarkCategory" => "notes",
        "picoTheme" => "slate",
        "semanticSimilarityEnabled" => true,
        "blogLanguages" => ["it"]
      })
    )

    File.write!(
      Path.join(meta_dir, "publishing.json"),
      Jason.encode!(%{
        "sshHost" => "files.example",
        "sshUser" => "files-user",
        "sshRemotePath" => "/srv/files",
        "sshMode" => "rsync"
      })
    )

    assert {:ok, diff} = BDS.Maintenance.metadata_diff(project.id)

    assert Enum.any?(diff.diff_reports, fn report ->
             report.entity_type == "project" and
               Enum.any?(
                 report.differences,
                 &(&1.name == "main_language" and &1.db_value == "en" and &1.file_value == "fr")
               )
           end)

    assert Enum.any?(diff.diff_reports, fn report ->
             report.entity_type == "publishing" and
               Enum.any?(
                 report.differences,
                 &(&1.name == "ssh_mode" and &1.db_value == "scp" and &1.file_value == "rsync")
               )
           end)
  end

  test "repair_metadata_diff syncs supported filesystem metadata back into the database", %{
    project: project,
    temp_dir: temp_dir
  } do
    fixture = seed_metadata_repair_fixture(project, temp_dir)

    File.write!(
      Path.join([temp_dir, "meta", "project.json"]),
      Jason.encode!(%{
        "name" => "Filesystem Blog",
        "description" => "Filesystem description",
        "publicUrl" => "https://filesystem.example",
        "mainLanguage" => "fr",
        "defaultAuthor" => "Filesystem Author",
        "maxPostsPerPage" => 12,
        "blogmarkCategory" => "notes",
        "picoTheme" => "slate",
        "semanticSimilarityEnabled" => true,
        "blogLanguages" => ["fr", "de"]
      })
    )

    File.write!(
      Path.join([temp_dir, "meta", "categories.json"]),
      Jason.encode!(["notes", "updates"])
    )

    File.write!(
      Path.join([temp_dir, "meta", "category-meta.json"]),
      Jason.encode!(%{
        "notes" => %{"title" => "Filesystem Notes", "showTitle" => false, "renderInLists" => true}
      })
    )

    File.write!(
      Path.join([temp_dir, "meta", "publishing.json"]),
      Jason.encode!(%{
        "sshHost" => "files.example",
        "sshUser" => "files-user",
        "sshRemotePath" => "/srv/files",
        "sshMode" => "rsync"
      })
    )

    write_post_frontmatter(
      fixture.post_path,
      %{
        "id" => fixture.post.id,
        "title" => "Filesystem Post",
        "slug" => fixture.post.slug,
        "excerpt" => "Filesystem summary",
        "status" => "published",
        "author" => "Filesystem Writer",
        "language" => "fr",
        "doNotTranslate" => false,
        "templateSlug" => nil,
        "createdAt" => fixture.post.created_at,
        "updatedAt" => fixture.post.updated_at + 1,
        "publishedAt" => fixture.post.published_at,
        "tags" => ["beta"],
        "categories" => ["updates"]
      },
      "Filesystem body"
    )

    write_post_frontmatter(
      fixture.post_translation_path,
      %{
        "id" => fixture.post_translation.id,
        "translationFor" => fixture.post_translation.translation_for,
        "language" => fixture.post_translation.language,
        "title" => "Datei Beitrag",
        "excerpt" => "Datei Zusammenfassung",
        "status" => "published",
        "createdAt" => fixture.post_translation.created_at,
        "updatedAt" => fixture.post_translation.updated_at + 1,
        "publishedAt" => fixture.post_translation.published_at
      },
      "Datei Inhalt"
    )

    File.write!(
      fixture.media_sidecar_path,
      [
        "id: #{fixture.media.id}",
        "originalName: #{fixture.media.original_name}",
        "mimeType: #{fixture.media.mime_type}",
        "size: #{fixture.media.size}",
        "title: Filesystem media title",
        "alt: Filesystem alt",
        "caption: Filesystem caption",
        "author: Filesystem Photographer",
        "language: fr",
        "createdAt: #{fixture.media.created_at}",
        "updatedAt: #{fixture.media.updated_at + 1}",
        "tags:",
        "  - beta",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      fixture.media_translation_sidecar_path,
      [
        "translationFor: #{fixture.media.id}",
        "language: #{fixture.media_translation.language}",
        "title: Datei Medium",
        "alt: Datei Alt",
        "caption: Datei Bildtext",
        ""
      ]
      |> Enum.join("\n")
    )

    write_script_frontmatter(
      fixture.script_path,
      fixture.script,
      %{
        "title" => "Filesystem Script",
        "entrypoint" => "run",
        "enabled" => false
      },
      "function run() return false end"
    )

    write_template_frontmatter(
      fixture.template_path,
      fixture.template,
      %{
        "title" => "Filesystem Template",
        "enabled" => false
      },
      "<section>Filesystem</section>"
    )

    items = [
      %{entity_type: "project", entity_id: project.id},
      %{entity_type: "categories", entity_id: project.id},
      %{entity_type: "category_meta", entity_id: project.id},
      %{entity_type: "publishing", entity_id: project.id},
      %{entity_type: "post", entity_id: fixture.post.id},
      %{entity_type: "post_translation", entity_id: fixture.post_translation.id},
      %{entity_type: "media", entity_id: fixture.media.id},
      %{entity_type: "media_translation", entity_id: fixture.media_translation.id},
      %{entity_type: "script", entity_id: fixture.script.id},
      %{entity_type: "template", entity_id: fixture.template.id}
    ]

    assert {:ok, %{repaired: 10, failed: 0}} =
             BDS.Maintenance.repair_metadata_diff(project.id, "file_to_db", items)

    assert {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
    assert metadata.name == "Filesystem Blog"
    assert metadata.categories == ["notes", "updates"]
    assert metadata.category_settings["notes"]["title"] == "Filesystem Notes"
    assert metadata.publishing_preferences["ssh_mode"] == "rsync"

    repaired_post = Repo.get!(BDS.Posts.Post, fixture.post.id)
    assert repaired_post.title == "Filesystem Post"
    assert repaired_post.excerpt == "Filesystem summary"
    assert repaired_post.author == "Filesystem Writer"
    assert repaired_post.language == "fr"
    assert repaired_post.tags == ["beta"]
    assert repaired_post.categories == ["updates"]

    repaired_translation = Repo.get!(BDS.Posts.Translation, fixture.post_translation.id)
    assert repaired_translation.title == "Datei Beitrag"
    assert repaired_translation.excerpt == "Datei Zusammenfassung"

    repaired_media = Repo.get!(BDS.Media.Media, fixture.media.id)
    assert repaired_media.title == "Filesystem media title"
    assert repaired_media.alt == "Filesystem alt"
    assert repaired_media.author == "Filesystem Photographer"
    assert repaired_media.language == "fr"
    assert repaired_media.tags == ["beta"]

    repaired_media_translation = Repo.get!(BDS.Media.Translation, fixture.media_translation.id)
    assert repaired_media_translation.title == "Datei Medium"
    assert repaired_media_translation.alt == "Datei Alt"

    repaired_script = Repo.get!(BDS.Scripts.Script, fixture.script.id)
    assert repaired_script.title == "Filesystem Script"
    assert repaired_script.entrypoint == "run"
    refute repaired_script.enabled

    repaired_template = Repo.get!(BDS.Templates.Template, fixture.template.id)
    assert repaired_template.title == "Filesystem Template"
    refute repaired_template.enabled
  end

  test "repair_metadata_diff syncs supported database metadata back into files", %{
    project: project,
    temp_dir: temp_dir
  } do
    fixture = seed_metadata_repair_fixture(project, temp_dir)

    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               name: "Database Blog",
               description: "Database description",
               public_url: "https://database.example",
               main_language: "en",
               default_author: "Database Author",
               max_posts_per_page: 25,
               blogmark_category: "article",
               pico_theme: "blue",
               semantic_similarity_enabled: false,
               blog_languages: ["en", "de"]
             })

    assert {:ok, _metadata} =
             BDS.Metadata.set_publishing_preferences(project.id, %{
               ssh_host: "db.example",
               ssh_user: "db-user",
               ssh_remote_path: "/srv/db",
               ssh_mode: "scp"
             })

    assert {:ok, _metadata} = BDS.Metadata.add_category(project.id, "guides")

    assert {:ok, _metadata} =
             BDS.Metadata.update_category_settings(project.id, "notes", %{
               title: "DB Notes",
               show_title: true
             })

    from(post in BDS.Posts.Post, where: post.id == ^fixture.post.id)
    |> Repo.update_all(
      set: [
        title: "Database Post",
        excerpt: "Database summary",
        author: "Database Writer",
        language: "en",
        tags: ["gamma"],
        categories: ["guides"],
        updated_at: fixture.post.updated_at + 2
      ]
    )

    from(translation in BDS.Posts.Translation,
      where: translation.id == ^fixture.post_translation.id
    )
    |> Repo.update_all(
      set: [
        title: "DB Beitrag",
        excerpt: "DB Zusammenfassung",
        updated_at: fixture.post_translation.updated_at + 2
      ]
    )

    from(media in BDS.Media.Media, where: media.id == ^fixture.media.id)
    |> Repo.update_all(
      set: [
        title: "Database media title",
        alt: "Database alt",
        caption: "Database caption",
        author: "Database Photographer",
        language: "en",
        tags: ["gamma"],
        updated_at: fixture.media.updated_at + 2
      ]
    )

    from(translation in BDS.Media.Translation,
      where: translation.id == ^fixture.media_translation.id
    )
    |> Repo.update_all(set: [title: "DB Medium", alt: "DB Alt", caption: "DB Bildtext"])

    from(script in BDS.Scripts.Script, where: script.id == ^fixture.script.id)
    |> Repo.update_all(
      set: [
        title: "Database Script",
        entrypoint: "run",
        enabled: false,
        updated_at: fixture.script.updated_at + 2
      ]
    )

    from(template in BDS.Templates.Template, where: template.id == ^fixture.template.id)
    |> Repo.update_all(
      set: [
        title: "Database Template",
        enabled: false,
        updated_at: fixture.template.updated_at + 2
      ]
    )

    items = [
      %{entity_type: "project", entity_id: project.id},
      %{entity_type: "categories", entity_id: project.id},
      %{entity_type: "category_meta", entity_id: project.id},
      %{entity_type: "publishing", entity_id: project.id},
      %{entity_type: "post", entity_id: fixture.post.id},
      %{entity_type: "post_translation", entity_id: fixture.post_translation.id},
      %{entity_type: "media", entity_id: fixture.media.id},
      %{entity_type: "media_translation", entity_id: fixture.media_translation.id},
      %{entity_type: "script", entity_id: fixture.script.id},
      %{entity_type: "template", entity_id: fixture.template.id}
    ]

    assert {:ok, %{repaired: 10, failed: 0}} =
             BDS.Maintenance.repair_metadata_diff(project.id, "db_to_file", items)

    project_json = Jason.decode!(File.read!(Path.join([temp_dir, "meta", "project.json"])))
    assert project_json["name"] == "Database Blog"
    assert project_json["mainLanguage"] == "en"

    categories_json = Jason.decode!(File.read!(Path.join([temp_dir, "meta", "categories.json"])))
    assert "guides" in categories_json

    category_meta_json =
      Jason.decode!(File.read!(Path.join([temp_dir, "meta", "category-meta.json"])))

    assert category_meta_json["notes"]["title"] == "DB Notes"

    publishing_json = Jason.decode!(File.read!(Path.join([temp_dir, "meta", "publishing.json"])))
    assert publishing_json["sshMode"] == "scp"

    assert File.read!(fixture.post_path) =~ "title: Database Post"
    assert File.read!(fixture.post_path) =~ "excerpt: Database summary"
    assert File.read!(fixture.post_translation_path) =~ "title: DB Beitrag"
    assert File.read!(fixture.media_sidecar_path) =~ ~s(title: "Database media title")
    assert File.read!(fixture.media_translation_sidecar_path) =~ ~s(title: "DB Medium")
    assert File.read!(fixture.script_path) =~ "title: Database Script"
    assert File.read!(fixture.script_path) =~ "entrypoint: run"
    assert File.read!(fixture.template_path) =~ "title: Database Template"
    assert File.read!(fixture.template_path) =~ "enabled: false"
  end

  test "import_metadata_diff_orphans imports orphan files for supported entity types", %{
    project: project,
    temp_dir: temp_dir
  } do
    fixture = seed_metadata_repair_fixture(project, temp_dir)

    post_orphan_path = "posts/2026/04/orphan-post.md"
    post_translation_orphan_path = "posts/2026/04/orphan-post.es.md"
    media_orphan_file_path = Path.join([temp_dir, "media", "2026", "04", "orphan.txt"])
    media_orphan_path = "media/2026/04/orphan.txt.meta"
    media_translation_orphan_path = "media/2026/04/orphan.txt.es.meta"
    script_orphan_path = "scripts/orphan.lua"
    template_orphan_path = "templates/orphan-view.liquid"

    File.mkdir_p!(Path.join([temp_dir, "posts", "2026", "04"]))
    File.mkdir_p!(Path.join([temp_dir, "media", "2026", "04"]))
    File.mkdir_p!(Path.join(temp_dir, "scripts"))
    File.mkdir_p!(Path.join(temp_dir, "templates"))

    File.write!(
      Path.join(temp_dir, post_orphan_path),
      [
        "---",
        "id: orphan-post",
        "title: Orphan Post",
        "slug: orphan-post",
        "status: published",
        "createdAt: 1",
        "updatedAt: 1",
        "publishedAt: 1",
        "tags:",
        "  - orphan",
        "categories:",
        "  - notes",
        "---",
        "Orphan body",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(temp_dir, post_translation_orphan_path),
      [
        "---",
        "id: orphan-post-es",
        "translationFor: #{fixture.post.id}",
        "language: es",
        "title: Verwaister Beitrag",
        "excerpt: Verwaiste Zusammenfassung",
        "status: published",
        "createdAt: 1",
        "updatedAt: 1",
        "publishedAt: 1",
        "---",
        "Verwaister Inhalt",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(media_orphan_file_path, "orphan media")

    File.write!(
      Path.join(temp_dir, media_orphan_path),
      [
        "id: orphan-media",
        "originalName: orphan.txt",
        "mimeType: text/plain",
        "size: 12",
        "title: Orphan Media",
        "createdAt: 1",
        "updatedAt: 1",
        "tags:",
        "  - orphan",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(temp_dir, media_translation_orphan_path),
      [
        "translationFor: orphan-media",
        "language: es",
        "title: Verwaistes Medium",
        "alt: Verwaister Alt",
        "caption: Verwaister Bildtext",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(temp_dir, script_orphan_path),
      [
        "---",
        "id: orphan-script",
        "projectId: #{project.id}",
        "slug: orphan-script",
        "title: Orphan Script",
        "kind: utility",
        "entrypoint: main",
        "enabled: true",
        "version: 1",
        "createdAt: 1",
        "updatedAt: 1",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(temp_dir, template_orphan_path),
      [
        "---",
        "id: orphan-template",
        "projectId: #{project.id}",
        "slug: orphan-view",
        "title: Orphan View",
        "kind: list",
        "enabled: true",
        "version: 1",
        "createdAt: 1",
        "updatedAt: 1",
        "---",
        "<section>Orphan</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, %{imported: 6, failed: 0}} =
             BDS.Maintenance.import_metadata_diff_orphans(project.id, [
               %{file_path: post_orphan_path},
               %{file_path: post_translation_orphan_path},
               %{file_path: media_orphan_path},
               %{file_path: media_translation_orphan_path},
               %{file_path: script_orphan_path},
               %{file_path: template_orphan_path}
             ])

    assert Repo.get_by(BDS.Posts.Post, project_id: project.id, file_path: post_orphan_path)

    assert Repo.get_by(BDS.Posts.Translation,
             project_id: project.id,
             file_path: post_translation_orphan_path
           )

    assert Repo.get_by(BDS.Media.Media, project_id: project.id, sidecar_path: media_orphan_path)

    assert Repo.get_by(BDS.Media.Translation,
             project_id: project.id,
             translation_for: "orphan-media",
             language: "es"
           )

    assert Repo.get_by(BDS.Scripts.Script, project_id: project.id, file_path: script_orphan_path)

    assert Repo.get_by(BDS.Templates.Template,
             project_id: project.id,
             file_path: template_orphan_path
           )
  end

  defp collect_progress_events(acc \\ []) do
    receive do
      {:rebuild_progress, value, message} -> collect_progress_events([{value, message} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_metadata_repair_fixture(project, temp_dir) do
    source_path = Path.join(temp_dir, "repair-source.txt")
    File.write!(source_path, "repair media")

    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               name: "Initial Blog",
               description: "Initial description",
               public_url: "https://initial.example",
               main_language: "en",
               default_author: "Initial Author",
               max_posts_per_page: 10,
               blogmark_category: "article",
               pico_theme: "amber",
               semantic_similarity_enabled: false,
               blog_languages: ["en"]
             })

    assert {:ok, _metadata} = BDS.Metadata.add_category(project.id, "notes")

    assert {:ok, _metadata} =
             BDS.Metadata.update_category_settings(project.id, "notes", %{
               title: "Initial Notes",
               show_title: true,
               render_in_lists: true
             })

    assert {:ok, _metadata} =
             BDS.Metadata.set_publishing_preferences(project.id, %{
               ssh_host: "initial.example",
               ssh_user: "initial-user",
               ssh_remote_path: "/srv/initial",
               ssh_mode: "scp"
             })

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Initial Post",
               content: "Initial body",
               excerpt: "Initial summary",
               author: "Initial Writer",
               language: "en",
               tags: ["alpha"],
               categories: ["notes"]
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, post_translation} =
             BDS.Posts.upsert_post_translation(published_post.id, "de", %{
               title: "Initial Beitrag",
               excerpt: "Initial Zusammenfassung",
               content: "Initial Inhalt"
             })

    assert {:ok, _republished_post} = BDS.Posts.publish_post(published_post.id)
    published_post_translation = Repo.get!(BDS.Posts.Translation, post_translation.id)

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Initial media title",
               alt: "Initial alt",
               caption: "Initial caption",
               author: "Initial Photographer",
               language: "en",
               tags: ["alpha"]
             })

    assert {:ok, _media_translation} =
             BDS.Media.upsert_media_translation(media.id, "de", %{
               title: "Initial Medium",
               alt: "Initial Alt",
               caption: "Initial Bildtext"
             })

    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Initial Script",
               kind: :utility,
               entrypoint: "main",
               content: "function main() return true end"
             })

    assert {:ok, published_script} = BDS.Scripts.publish_script(script.id)

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Initial Template",
               kind: :list,
               content: "<section>Initial</section>"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    %{
      post: Repo.get!(BDS.Posts.Post, published_post.id),
      post_path: Path.join(temp_dir, published_post.file_path),
      post_translation: published_post_translation,
      post_translation_path: Path.join(temp_dir, published_post_translation.file_path),
      media: Repo.get!(BDS.Media.Media, media.id),
      media_sidecar_path: Path.join(temp_dir, media.sidecar_path),
      media_translation:
        Repo.get_by!(BDS.Media.Translation, translation_for: media.id, language: "de"),
      media_translation_sidecar_path: Path.join(temp_dir, "#{media.file_path}.de.meta"),
      script: Repo.get!(BDS.Scripts.Script, published_script.id),
      script_path: Path.join(temp_dir, published_script.file_path),
      template: Repo.get!(BDS.Templates.Template, published_template.id),
      template_path: Path.join(temp_dir, published_template.file_path)
    }
  end

  defp write_post_frontmatter(path, fields, body) do
    frontmatter =
      [
        "---",
        "id: #{fields["id"]}",
        if(fields["translationFor"],
          do: "translationFor: #{fields["translationFor"]}",
          else: nil
        ),
        if(fields["title"], do: "title: #{fields["title"]}", else: nil),
        if(fields["slug"], do: "slug: #{fields["slug"]}", else: nil),
        if(fields["excerpt"], do: "excerpt: #{fields["excerpt"]}", else: nil),
        if(fields["status"], do: "status: #{fields["status"]}", else: nil),
        if(fields["author"], do: "author: #{fields["author"]}", else: nil),
        if(fields["language"], do: "language: #{fields["language"]}", else: nil),
        if(Map.has_key?(fields, "doNotTranslate"),
          do: "doNotTranslate: #{fields["doNotTranslate"]}",
          else: nil
        ),
        if(Map.has_key?(fields, "templateSlug"),
          do: "templateSlug: #{fields["templateSlug"] || ""}",
          else: nil
        ),
        "createdAt: #{fields["createdAt"]}",
        "updatedAt: #{fields["updatedAt"]}",
        if(fields["publishedAt"], do: "publishedAt: #{fields["publishedAt"]}", else: nil),
        if(Map.has_key?(fields, "tags"),
          do: ["tags:" | Enum.map(fields["tags"], &"  - #{&1}")],
          else: nil
        ),
        if(Map.has_key?(fields, "categories"),
          do: ["categories:" | Enum.map(fields["categories"], &"  - #{&1}")],
          else: nil
        ),
        "---",
        body,
        ""
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    File.write!(path, frontmatter)
  end

  defp write_script_frontmatter(path, script, overrides, body) do
    File.write!(
      path,
      [
        "---",
        "id: #{script.id}",
        "projectId: #{script.project_id}",
        "slug: #{script.slug}",
        "title: #{Map.get(overrides, "title", script.title)}",
        "kind: #{script.kind}",
        "entrypoint: #{Map.get(overrides, "entrypoint", script.entrypoint)}",
        "enabled: #{Map.get(overrides, "enabled", script.enabled)}",
        "version: #{script.version}",
        "createdAt: #{script.created_at}",
        "updatedAt: #{script.updated_at}",
        "---",
        body,
        ""
      ]
      |> Enum.join("\n")
    )
  end

  defp write_template_frontmatter(path, template, overrides, body) do
    File.write!(
      path,
      [
        "---",
        "id: #{template.id}",
        "projectId: #{template.project_id}",
        "slug: #{template.slug}",
        "title: #{Map.get(overrides, "title", template.title)}",
        "kind: #{template.kind}",
        "enabled: #{Map.get(overrides, "enabled", template.enabled)}",
        "version: #{template.version}",
        "createdAt: #{template.created_at}",
        "updatedAt: #{template.updated_at}",
        "---",
        body,
        ""
      ]
      |> Enum.join("\n")
    )
  end

  defp assert_incremental_progress(events) do
    assert Enum.any?(events, fn {value, _message} -> value > 0.0 and value < 1.0 end)
    assert Enum.any?(events, fn {value, _message} -> value == 1.0 end)
  end
end
