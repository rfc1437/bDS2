defmodule BDS.PostsTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-posts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Publishing", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "create_post slugifies titles, stores list fields, and defaults draft fields", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Über Café",
               content: "draft body",
               tags: ["elixir", "sqlite"],
               categories: ["notes"],
               author: "G",
               language: "de",
               template_slug: "article"
             })

    assert post.title == "Über Café"
    assert post.slug == "uber-cafe"
    assert post.status == :draft
    assert post.file_path == ""
    assert post.do_not_translate == false
    assert post.tags == ["elixir", "sqlite"]
    assert post.categories == ["notes"]
    assert post.author == "G"
    assert post.language == "de"
    assert post.template_slug == "article"
    assert post.project_id == project.id
    assert is_integer(post.created_at)
    assert is_integer(post.updated_at)

    assert {:ok, duplicate_slug_post} =
             BDS.Posts.create_post(%{project_id: project.id, title: "Über Café"})

    assert duplicate_slug_post.slug == "uber-cafe-2"
    assert duplicate_slug_post.tags == []
    assert duplicate_slug_post.categories == []
  end

  test "create_post falls back to untitled and keeps slug uniqueness scoped to a project", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, first} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert first.title == ""
    assert first.slug == "untitled"

    assert {:ok, second} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert second.slug == "untitled-2"

    other_temp_dir = Path.join(temp_dir, "elsewhere")
    File.mkdir_p!(other_temp_dir)

    assert {:ok, other_project} =
             BDS.Projects.create_project(%{name: "Elsewhere", data_path: other_temp_dir})

    assert {:ok, other_post} = BDS.Posts.create_post(%{project_id: other_project.id, title: nil})
    assert other_post.slug == "untitled"
  end

  test "update_post rejects slug changes after first publish and reopens published posts when content changes",
       %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Stable Slug",
               content: "first body"
             })

    published_at = System.system_time(:second) - 5

    {:ok, published} =
      BDS.Posts.update_post(post.id, %{
        status: :published,
        published_at: published_at,
        content: nil,
        file_path: "posts/2026/04/stable-slug.md"
      })

    assert published.status == :published
    assert published.published_at == published_at

    assert {:error, changeset} = BDS.Posts.update_post(post.id, %{slug: "new-slug"})
    assert "cannot change slug after first publish" in errors_on(changeset).slug

    assert {:ok, reopened} = BDS.Posts.update_post(post.id, %{content: "revised draft"})
    assert reopened.status == :draft
    assert reopened.slug == "stable-slug"
    assert reopened.published_at == published_at
    assert reopened.content == "revised draft"
    assert reopened.updated_at >= published.updated_at
  end

  test "update_post keeps published posts published and rewrites the file when only template_slug changes",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Template Rewrite",
               content: "Body",
               template_slug: "article"
             })

    assert {:ok, published} = BDS.Posts.publish_post(post.id)

    full_path = Path.join(temp_dir, published.file_path)
    original_contents = File.read!(full_path)

    assert original_contents =~ "templateSlug: article\n"

    assert {:ok, updated} =
             BDS.Posts.update_post(post.id, %{template_slug: "landing-page"})

    assert updated.status == :published
    assert updated.template_slug == "landing-page"
    assert updated.file_path == published.file_path

    rewritten_contents = File.read!(full_path)
    assert rewritten_contents =~ "templateSlug: landing-page\n"
    refute rewritten_contents =~ "templateSlug: article\n"
  end

  test "publish_post writes frontmatter to the project data directory and clears draft content" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-publish-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Filesystem", data_path: temp_dir})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Published Post",
               excerpt: "Summary",
               content: "Hello from markdown",
               tags: ["alpha"],
               categories: ["notes"],
               author: "Writer",
               language: "en",
               template_slug: "article"
             })

    assert {:ok, post} = BDS.Posts.update_post(post.id, %{do_not_translate: true})
    assert {:ok, published} = BDS.Posts.publish_post(post.id)

    assert published.status == :published
    assert published.content == nil
    assert published.file_path =~ ~r/^posts\/\d{4}\/\d{2}\/published-post\.md$/
    assert is_integer(published.published_at)

    full_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(full_path)

    file_contents = File.read!(full_path)

    assert file_contents =~ "---\nid: #{published.id}\n"
    assert file_contents =~ "title: Published Post\n"
    assert file_contents =~ "slug: published-post\n"
    assert file_contents =~ "status: published\n"
    assert file_contents =~ "excerpt: Summary\n"
    assert file_contents =~ "author: Writer\n"
    assert file_contents =~ "language: en\n"
    assert file_contents =~ "doNotTranslate: true\n"
    assert file_contents =~ "templateSlug: article\n"
    assert file_contents =~ "tags:\n  - alpha\n"
    assert file_contents =~ "categories:\n  - notes\n"
    assert file_contents =~ ~r/createdAt: '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'\n/
    assert file_contents =~ ~r/updatedAt: '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'\n/
    assert file_contents =~ ~r/publishedAt: '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'\n/
    assert file_contents =~ "\n---\nHello from markdown\n"

    refute File.exists?(full_path <> ".tmp")
  end

  test "publish_post deletes old file when file path changes", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Moving Post",
               content: "Body"
             })

    assert {:ok, published} = BDS.Posts.publish_post(post.id)
    new_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(new_path)

    old_relative = "posts/1999/01/moving-post.md"
    old_full = Path.join(temp_dir, old_relative)
    File.mkdir_p!(Path.dirname(old_full))
    File.write!(old_full, "stale content")

    import Ecto.Query
    BDS.Repo.update_all(
      from(p in BDS.Posts.Post, where: p.id == ^published.id),
      set: [file_path: old_relative, content: "edited body"]
    )

    assert {:ok, republished} = BDS.Posts.publish_post(published.id)
    assert republished.file_path == published.file_path

    assert File.exists?(Path.join(temp_dir, republished.file_path))
    refute File.exists?(old_full)
  end

  test "delete_post removes the database row and published markdown file when present" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-delete-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} = BDS.Projects.create_project(%{name: "Delete", data_path: temp_dir})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Delete Me",
               content: "Body"
             })

    assert {:ok, published} = BDS.Posts.publish_post(post.id)
    full_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(full_path)

    assert {:ok, :deleted} = BDS.Posts.delete_post(published.id)

    assert BDS.Repo.get(BDS.Posts.Post, published.id) == nil
    refute File.exists?(full_path)
  end

  test "delete_post removes DB row before cleaning up side effects", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Atomic Delete",
               content: "Body"
             })

    assert {:ok, :deleted} = BDS.Posts.delete_post(post.id)
    assert BDS.Repo.get(BDS.Posts.Post, post.id) == nil

    assert {:error, :not_found} = BDS.Posts.delete_post(post.id)
  end

  test "delete_post deletes translation records and their files from disk" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-del-trans-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "DelTrans", data_path: temp_dir})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Parent Post",
               content: "Body"
             })

    assert {:ok, translation} =
             BDS.Posts.upsert_post_translation(post.id, "de", %{
               title: "Elternbeitrag",
               content: "Inhalt"
             })

    assert {:ok, _published} = BDS.Posts.publish_post(post.id)

    published_translation = BDS.Posts.get_post_translation!(translation.id)
    translation_path = Path.join(temp_dir, published_translation.file_path)
    assert File.exists?(translation_path)

    assert {:ok, :deleted} = BDS.Posts.delete_post(post.id)

    assert BDS.Repo.get(BDS.Posts.Post, post.id) == nil
    assert {:ok, []} = BDS.Posts.list_post_translations(post.id)

    refute File.exists?(translation_path)
  end

  test "delete_post returns not_found for nonexistent post" do
    assert {:error, :not_found} = BDS.Posts.delete_post(Ecto.UUID.generate())
  end

  test "archive_post transitions draft and published posts to archived", %{project: project} do
    assert {:ok, draft_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Draft Archive",
               content: "Body"
             })

    assert {:ok, archived_draft} = BDS.Posts.archive_post(draft_post.id)
    assert archived_draft.status == :archived

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, publish_project} =
             BDS.Projects.create_project(%{name: "Archive Published", data_path: temp_dir})

    assert {:ok, published_post} =
             BDS.Posts.create_post(%{
               project_id: publish_project.id,
               title: "Published Archive",
               content: "Body"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(published_post.id)
    assert {:ok, archived_published} = BDS.Posts.archive_post(published_post.id)

    assert archived_published.status == :archived
    assert archived_published.file_path == published_post.file_path
    assert archived_published.published_at == published_post.published_at
  end

  test "publish_post republishes archived posts without losing the existing body or original published_at" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-republish-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} = BDS.Projects.create_project(%{name: "Republish", data_path: temp_dir})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Republish Me",
               content: "Body"
             })

    assert {:ok, published} = BDS.Posts.publish_post(post.id)
    assert {:ok, archived} = BDS.Posts.archive_post(published.id)
    assert archived.status == :archived
    assert archived.content == nil

    assert {:ok, republished} = BDS.Posts.publish_post(archived.id)
    assert republished.status == :published
    assert republished.published_at == published.published_at

    contents = File.read!(Path.join(temp_dir, republished.file_path))
    assert contents =~ "\n---\nBody\n"
  end

  test "unarchive_post transitions archived draft back to draft", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Archive Then Unarchive",
               content: "Draft body"
             })

    assert {:ok, archived} = BDS.Posts.archive_post(post.id)
    assert archived.status == :archived

    assert {:ok, unarchived} = BDS.Posts.unarchive_post(archived.id)
    assert unarchived.status == :draft
    assert unarchived.content == "Draft body"
  end

  test "unarchive_post restores content from disk for previously published posts" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-unarchive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Unarchive Pub", data_path: temp_dir})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Publish Then Archive",
               content: "Published body"
             })

    assert {:ok, published} = BDS.Posts.publish_post(post.id)
    assert published.content == nil
    assert {:ok, archived} = BDS.Posts.archive_post(published.id)
    assert archived.status == :archived
    assert archived.content == nil

    assert {:ok, unarchived} = BDS.Posts.unarchive_post(archived.id)
    assert unarchived.status == :draft
    assert unarchived.content == "Published body"
  end

  test "unarchive_post rejects non-archived posts", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Still Draft",
               content: "Body"
             })

    assert {:error, %Ecto.Changeset{}} = BDS.Posts.unarchive_post(post.id)
  end

  test "unarchive_post returns not_found for nonexistent post" do
    assert {:error, :not_found} = BDS.Posts.unarchive_post(Ecto.UUID.generate())
  end

  test "rebuild_posts_from_files recreates published posts from disk" do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-rebuild-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} = BDS.Projects.create_project(%{name: "Rebuild", data_path: temp_dir})

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    file_path = Path.join(posts_dir, "recovered-post.md")

    File.write!(
      file_path,
      [
        "---",
        "id: post-from-file",
        "title: Recovered Post",
        "slug: recovered-post",
        "excerpt: Summary",
        "status: published",
        "author: Writer",
        "language: en",
        "doNotTranslate: true",
        "templateSlug: article",
        "createdAt: 2024-03-30T21:20:00.000Z",
        "updatedAt: 2024-03-31T21:20:00.000Z",
        "publishedAt: 2024-04-01T21:20:00.000Z",
        "tags:",
        "  - alpha",
        "categories:",
        "  - notes",
        "---",
        "Restored body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, posts} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert length(posts) == 1

    [post] = posts
    assert post.id == "post-from-file"
    assert post.project_id == project.id
    assert post.title == "Recovered Post"
    assert post.slug == "recovered-post"
    assert post.excerpt == "Summary"
    assert post.status == :published
    assert post.author == "Writer"
    assert post.language == "en"
    assert post.do_not_translate == true
    assert post.template_slug == "article"
    assert post.created_at == 1_711_833_600_000
    assert post.updated_at == 1_711_920_000_000
    assert post.published_at == 1_712_006_400_000
    assert post.tags == ["alpha"]
    assert post.categories == ["notes"]
    assert post.file_path == "posts/2026/04/recovered-post.md"
    assert post.content == nil
  end

  test "rebuild_posts_from_files imports canonical bDS translation files alongside canonical posts" do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "bds-post-rebuild-legacy-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Legacy Rebuild", data_path: temp_dir})

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

    assert {:ok, posts} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert length(posts) == 1

    [post] = posts
    assert post.id == "post-from-old-app"
    assert post.slug == "chimera"
    assert post.language == "de"

    assert {:ok, translations} = BDS.Posts.list_post_translations(post.id)
    assert length(translations) == 1

    [translation] = translations
    assert translation.id == "translation-from-old-app"
    assert translation.translation_for == post.id
    assert translation.project_id == project.id
    assert translation.language == "en"
    assert translation.title == "Chimera"
    assert translation.excerpt == "Imported translation"
    assert translation.status == :published
    assert translation.file_path == "posts/2026/04/chimera.en.md"
    assert translation.content == nil
  end

  test "rebuild_posts_from_files parses quoted canonical timestamps and inline empty tag arrays" do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "bds-post-rebuild-quoted-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Quoted Rebuild", data_path: temp_dir})

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2002", "11"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "p10.md"),
      [
        "---",
        "id: 1c1ecaeb-c94c-446a-9291-e946cb991637",
        "title: Chimera",
        "slug: p10",
        "status: published",
        "language: de",
        "createdAt: '2002-11-05T12:00:00.000Z'",
        "updatedAt: '2026-03-04T14:11:28.000Z'",
        "publishedAt: '2002-11-05T12:00:00.000Z'",
        "tags: []",
        "categories:",
        "  - article",
        "---",
        "Quelle",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, [post]} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert post.id == "1c1ecaeb-c94c-446a-9291-e946cb991637"
    assert post.slug == "p10"
    assert post.tags == []
    assert post.categories == ["article"]
    assert post.created_at == 1_036_497_600_000
    assert post.updated_at == 1_772_633_488_000
    assert post.published_at == 1_036_497_600_000
  end

  test "rebuild_posts_from_files returns an error for unreadable post files", %{project: project} do
    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    file_path = Path.join(posts_dir, "unreadable.md")
    File.mkdir_p!(file_path)

    assert {:error, {:read_rebuild_file, ^file_path, :eisdir}} =
             BDS.Posts.rebuild_posts_from_files(project.id)
  end

  test "rebuild_posts_from_files parses folded multiline title and slug scalars alongside translations" do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "bds-post-rebuild-folded-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Folded Rebuild", data_path: temp_dir})

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2010", "11"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(
        posts_dir,
        "introducing-thirty-ten-my-guide-to-creating-a-twenty-ten-child-theme-aaron-jorb-inaaron-jorb-in.md"
      ),
      [
        "---",
        "id: 66865ffe-c6d9-4379-a031-0581f33b68b4",
        "title: >-",
        "  Introducing Thirty Ten, my guide to creating a Twenty Ten Child Theme |",
        "  aaron.jorb.inaaron.jorb.in",
        "slug: >-",
        "  introducing-thirty-ten-my-guide-to-creating-a-twenty-ten-child-theme-aaron-jorb-inaaron-jorb-in",
        "status: published",
        "createdAt: '2010-11-13T12:37:55.000Z'",
        "updatedAt: '2026-03-03T12:31:37.661Z'",
        "tags:",
        "  - wordpress",
        "categories:",
        "  - aside",
        "author: hugo",
        "language: de",
        "publishedAt: '2010-11-13T11:37:55.000Z'",
        "---",
        "Quelle",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      Path.join(
        posts_dir,
        "introducing-thirty-ten-my-guide-to-creating-a-twenty-ten-child-theme-aaron-jorb-inaaron-jorb-in.en.md"
      ),
      [
        "---",
        "translationFor: 66865ffe-c6d9-4379-a031-0581f33b68b4",
        "language: en",
        "title: >-",
        "  Introducing Thirty Ten, my guide to creating a Twenty Ten Child Theme |",
        "  aaron.jorb.inaaron.jorb.in",
        "---",
        "Translated body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, [post]} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert post.id == "66865ffe-c6d9-4379-a031-0581f33b68b4"

    assert post.slug ==
             "introducing-thirty-ten-my-guide-to-creating-a-twenty-ten-child-theme-aaron-jorb-inaaron-jorb-in"

    assert post.title ==
             "Introducing Thirty Ten, my guide to creating a Twenty Ten Child Theme | aaron.jorb.inaaron.jorb.in"

    assert {:ok, [translation]} = BDS.Posts.list_post_translations(post.id)

    assert translation.translation_for == post.id

    assert translation.title ==
             "Introducing Thirty Ten, my guide to creating a Twenty Ten Child Theme | aaron.jorb.inaaron.jorb.in"
  end

  test "rebuild_posts_from_files realigns an existing slug match to the canonical file id before importing translations",
       %{project: project} do
    assert {:ok, _stale_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Old Title",
               slug: "chimera",
               content: "stale body"
             })

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "chimera.md"),
      [
        "---",
        "id: canonical-post-id",
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
        "translationFor: canonical-post-id",
        "language: en",
        "title: Chimera",
        "excerpt: Imported translation",
        "---",
        "Translated body",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, [post]} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert post.id == "canonical-post-id"
    assert post.slug == "chimera"

    assert {:ok, [translation]} = BDS.Posts.list_post_translations(post.id)
    assert translation.translation_for == post.id
  end

  test "rebuild_posts_from_files repairs a stale row that matches by file path but has a broken slug",
       %{project: project} do
    now = BDS.Persistence.now_ms()
    relative_path = "posts/2010/11/chimera.md"

    stale_post =
      %BDS.Posts.Post{}
      |> BDS.Posts.Post.changeset(%{
        id: "stale-post-id",
        project_id: project.id,
        title: ">-",
        slug: ">-",
        status: :published,
        created_at: now,
        updated_at: now,
        file_path: relative_path,
        do_not_translate: false
      })
      |> BDS.Repo.insert!()

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2010", "11"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "chimera.md"),
      [
        "---",
        "id: canonical-post-id",
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

    assert {:ok, [post]} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert post.id == "canonical-post-id"
    assert post.slug == "chimera"

    posts =
      BDS.Repo.all(BDS.Posts.Post)
      |> Enum.filter(&(&1.project_id == project.id))

    assert length(posts) == 1
    refute BDS.Repo.get(BDS.Posts.Post, stale_post.id)
  end

  test "rebuild_posts_from_files batches search and embedding refresh after import", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    posts_dir = Path.join([BDS.Projects.project_data_dir(project), "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    Enum.each(1..3, fn index ->
      slug = "batched-post-#{index}"

      File.write!(
        Path.join(posts_dir, "#{slug}.md"),
        [
          "---",
          "id: #{slug}",
          "title: Batched Post #{index}",
          "slug: #{slug}",
          "status: published",
          "language: en",
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

    handler_id = "posts-rebuild-batch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bds, :repo, :query],
        &__MODULE__.handle_repo_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, posts} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert length(posts) == 3

    queries = drain_repo_queries([])

    assert count_queries(queries, "settings") <= 12
    assert count_queries(queries, "posts_fts") <= 4

    assert {:ok, results} = BDS.Search.search_posts(project.id, "Batched Post", %{})
    assert results.total == 3

    assert {:ok, %{indexed: 3, total: 3}} = BDS.Embeddings.get_indexing_progress(project.id)
  end

  test "validate_translations and fix_invalid_translations follow the legacy invalid-translation workflow",
       %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Source Post",
               content: "Canonical body",
               language: "en"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, translation} =
             BDS.Posts.upsert_post_translation(post.id, "de", %{
               title: "Translated Post",
               content: "Translated body",
               status: :published
             })

    invalid_file_path =
      Path.join([
        BDS.Projects.project_data_dir(project),
        Path.dirname(published_post.file_path),
        "#{published_post.slug}.en.md"
      ])

    File.write!(
      invalid_file_path,
      [
        "---",
        "translationFor: #{post.id}",
        "language: en",
        "title: Invalid Same Language",
        "---",
        "Wrong translation",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, report} = BDS.Posts.validate_translations(project.id)

    assert report.checked_database_row_count == 1
    assert report.checked_filesystem_file_count == 1

    assert [db_issue] = report.invalid_database_rows
    assert db_issue.issue == "content-in-database"
    assert db_issue.translation_id == translation.id
    assert db_issue.translation_for == post.id
    assert db_issue.translation_language == "de"

    assert [file_issue] = report.invalid_filesystem_files
    assert file_issue.issue == "same-language-as-canonical"
    assert file_issue.translation_for == post.id
    assert file_issue.translation_language == "en"
    assert file_issue.file_path == invalid_file_path

    assert {:ok, result} = BDS.Posts.fix_invalid_translations(report)
    assert result.deleted_database_rows == 0
    assert result.deleted_files == 1
    assert result.flushed_translations == 1

    saved_translation = BDS.Repo.get!(BDS.Posts.Translation, translation.id)
    assert saved_translation.content == nil
    assert is_binary(saved_translation.file_path)

    assert File.exists?(
             Path.join(BDS.Projects.project_data_dir(project), saved_translation.file_path)
           )

    refute File.exists?(invalid_file_path)
  end

  def handle_repo_query(_event, _measurements, metadata, owner_pid) do
    send(owner_pid, {:repo_query, metadata.query || ""})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp drain_repo_queries(acc) do
    receive do
      {:repo_query, query} -> drain_repo_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_queries(queries, fragment) do
    Enum.count(queries, &String.contains?(&1, fragment))
  end
end
