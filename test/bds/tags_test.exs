defmodule BDS.TagsTest do
  use ExUnit.Case, async: false

  alias BDS.Posts.Post
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-tags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Tags", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "create_tag persists the row and rewrites meta/tags.json sorted by name", %{project: project, temp_dir: temp_dir} do
    assert {:ok, zebra} = BDS.Tags.create_tag(%{project_id: project.id, name: "Zebra", color: "#000000"})
    assert {:ok, alpha} = BDS.Tags.create_tag(%{project_id: project.id, name: "Alpha"})

    assert zebra.name == "Zebra"
    assert zebra.color == "#000000"
    assert alpha.color == nil

    tags_path = Path.join([temp_dir, "meta", "tags.json"])
    assert File.exists?(tags_path)

    assert %{"tags" => [%{"name" => "Alpha"}, %{"color" => "#000000", "name" => "Zebra"}]} =
             Jason.decode!(File.read!(tags_path))
  end

  test "create_tag rejects case-insensitive duplicates per project", %{project: project} do
    assert {:ok, _tag} = BDS.Tags.create_tag(%{project_id: project.id, name: "Elixir"})
    assert {:error, changeset} = BDS.Tags.create_tag(%{project_id: project.id, name: "elixir"})
    assert "has already been taken" in errors_on(changeset).name
  end

  test "update_tag rewrites the tag row and meta/tags.json", %{project: project, temp_dir: temp_dir} do
    assert {:ok, tag} = BDS.Tags.create_tag(%{project_id: project.id, name: "Alpha"})

    assert {:ok, updated} =
             BDS.Tags.update_tag(tag.id, %{
               color: "#112233",
               post_template_slug: "article"
             })

    assert updated.name == "Alpha"
    assert updated.color == "#112233"
    assert updated.post_template_slug == "article"
    assert updated.updated_at >= tag.updated_at

    tags_path = Path.join([temp_dir, "meta", "tags.json"])

    assert %{"tags" => [%{"name" => "Alpha", "color" => "#112233", "post_template_slug" => "article"}]} =
             Jason.decode!(File.read!(tags_path))
  end

  test "rename_tag updates post tag arrays, rewrites published post files, and refreshes tags.json", %{project: project, temp_dir: temp_dir} do
    assert {:ok, tag} = BDS.Tags.create_tag(%{project_id: project.id, name: "Alpha"})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Tagged Post",
               content: "Body",
               tags: ["Alpha", "Other"]
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, renamed} = BDS.Tags.rename_tag(tag.id, "Beta")
    assert renamed.name == "Beta"

    reloaded_post = Repo.get!(Post, published_post.id)
    assert reloaded_post.tags == ["Beta", "Other"]

    post_path = Path.join(temp_dir, reloaded_post.file_path)
    contents = File.read!(post_path)
    assert contents =~ "tags:\n  - Beta\n  - Other\n"
    assert contents =~ "\n---\nBody\n"

    tags_path = Path.join([temp_dir, "meta", "tags.json"])
    assert %{"tags" => [%{"name" => "Beta"}]} = Jason.decode!(File.read!(tags_path))
  end

  test "merge_tags moves source tags onto the target, deduplicates post tags, deletes sources, and refreshes tags.json", %{project: project, temp_dir: temp_dir} do
    assert {:ok, source_a} = BDS.Tags.create_tag(%{project_id: project.id, name: "Alpha"})
    assert {:ok, source_b} = BDS.Tags.create_tag(%{project_id: project.id, name: "Beta"})
    assert {:ok, target} = BDS.Tags.create_tag(%{project_id: project.id, name: "Gamma"})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Merge Me",
               content: "Body",
               tags: ["Alpha", "Beta", "Gamma"]
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, :merged} = BDS.Tags.merge_tags([source_a.id, source_b.id], target.id)

    reloaded_post = Repo.get!(Post, published_post.id)
    assert reloaded_post.tags == ["Gamma"]
    assert Repo.get(BDS.Tags.Tag, source_a.id) == nil
    assert Repo.get(BDS.Tags.Tag, source_b.id) == nil
    assert Repo.get(BDS.Tags.Tag, target.id) != nil

    post_path = Path.join(temp_dir, reloaded_post.file_path)
    contents = File.read!(post_path)
    assert contents =~ "tags:\n  - Gamma\n"
    assert contents =~ "\n---\nBody\n"

    tags_path = Path.join([temp_dir, "meta", "tags.json"])
    assert %{"tags" => [%{"name" => "Gamma"}]} = Jason.decode!(File.read!(tags_path))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
