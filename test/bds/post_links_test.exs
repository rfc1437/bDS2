defmodule BDS.PostLinksTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-links-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Links", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "publishing and updating posts sync outgoing post links and deleting a post removes them",
       %{
         project: project
       } do
    assert {:ok, target} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Target Post",
               content: "target body"
             })

    assert {:ok, target} = BDS.Posts.publish_post(target.id)

    target_href = canonical_post_href(target)

    assert {:ok, source} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Source Post",
               content: "See [Target](#{target_href})"
             })

    assert {:ok, source} = BDS.Posts.publish_post(source.id)

    assert post_links() == [
             %{
               source_post_id: source.id,
               target_post_id: target.id,
               link_text: "Target"
             }
           ]

    assert {:ok, source} =
             BDS.Posts.update_post(source.id, %{
               content: "A revised body without a post reference"
             })

    assert source.status == :draft
    assert post_links() == []

    assert {:ok, source} =
             BDS.Posts.update_post(source.id, %{
               content: "Now [Target Again](#{target_href})"
             })

    assert {:ok, source} = BDS.Posts.publish_post(source.id)

    assert post_links() == [
             %{
               source_post_id: source.id,
               target_post_id: target.id,
               link_text: "Target Again"
             }
           ]

    assert {:ok, :deleted} = BDS.Posts.delete_post(target.id)
    assert post_links() == []
  end

  defp canonical_post_href(post) do
    datetime = DateTime.from_unix!(post.created_at, :millisecond)

    Path.join([
      "",
      Integer.to_string(datetime.year),
      String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
      String.pad_leading(Integer.to_string(datetime.day), 2, "0"),
      post.slug,
      ""
    ])
  end

  defp post_links do
    Repo.query!(
      "SELECT source_post_id, target_post_id, link_text FROM post_links ORDER BY source_post_id, target_post_id",
      []
    ).rows
    |> Enum.map(fn [source_post_id, target_post_id, link_text] ->
      %{source_post_id: source_post_id, target_post_id: target_post_id, link_text: link_text}
    end)
  end
end
