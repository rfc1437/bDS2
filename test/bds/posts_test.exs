defmodule BDS.PostsTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    {:ok, project} = BDS.Projects.create_project(%{name: "Publishing"})
    %{project: project}
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

  test "create_post falls back to untitled and keeps slug uniqueness scoped to a project", %{project: project} do
    assert {:ok, first} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert first.title == ""
    assert first.slug == "untitled"

    assert {:ok, second} = BDS.Posts.create_post(%{project_id: project.id, title: nil})
    assert second.slug == "untitled-2"

    assert {:ok, other_project} = BDS.Projects.create_project(%{name: "Elsewhere"})
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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
