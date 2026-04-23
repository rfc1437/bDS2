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

  test "create_post slugifies titles, stores list fields, and defaults draft fields", %{project: project} do
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

  test "create_post falls back to untitled and keeps slug uniqueness scoped to a project", %{project: project, temp_dir: temp_dir} do
    assert {:ok, first} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert first.title == ""
    assert first.slug == "untitled"

    assert {:ok, second} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert second.slug == "untitled-2"

    other_temp_dir = Path.join(temp_dir, "elsewhere")
    File.mkdir_p!(other_temp_dir)

    assert {:ok, other_project} = BDS.Projects.create_project(%{name: "Elsewhere", data_path: other_temp_dir})
    assert {:ok, other_post} = BDS.Posts.create_post(%{project_id: other_project.id, title: nil})
    assert other_post.slug == "untitled"
  end

  test "update_post rejects slug changes after first publish and reopens published posts when content changes", %{project: project} do
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

  test "publish_post writes frontmatter to the project data directory and clears draft content" do
    temp_dir = Path.join(System.tmp_dir!(), "bds-post-publish-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, project} = BDS.Projects.create_project(%{name: "Filesystem", data_path: temp_dir})

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
    assert file_contents =~ "do_not_translate: true\n"
    assert file_contents =~ "template_slug: article\n"
    assert file_contents =~ "tags:\n  - alpha\n"
    assert file_contents =~ "categories:\n  - notes\n"
    assert file_contents =~ "\n---\nHello from markdown\n"
  end

  test "delete_post removes the database row and published markdown file when present" do
    temp_dir = Path.join(System.tmp_dir!(), "bds-post-delete-#{System.unique_integer([:positive])}")
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

  test "archive_post transitions draft and published posts to archived", %{project: project} do
    assert {:ok, draft_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Draft Archive",
               content: "Body"
             })

    assert {:ok, archived_draft} = BDS.Posts.archive_post(draft_post.id)
    assert archived_draft.status == :archived

    temp_dir = Path.join(System.tmp_dir!(), "bds-post-archive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert {:ok, publish_project} = BDS.Projects.create_project(%{name: "Archive Published", data_path: temp_dir})

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
    temp_dir = Path.join(System.tmp_dir!(), "bds-post-republish-#{System.unique_integer([:positive])}")
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

  test "rebuild_posts_from_files recreates published posts from disk" do
    temp_dir = Path.join(System.tmp_dir!(), "bds-post-rebuild-#{System.unique_integer([:positive])}")
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
        "do_not_translate: true",
        "template_slug: article",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "published_at: 1712016000",
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
    assert post.created_at == 1711843200
    assert post.updated_at == 1711929600
    assert post.published_at == 1712016000
    assert post.tags == ["alpha"]
    assert post.categories == ["notes"]
    assert post.file_path == "posts/2026/04/recovered-post.md"
    assert post.content == nil
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
