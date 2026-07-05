defmodule BDS.Media.LinkRestoreTest do
  @moduledoc """
  Guards the regression where gallery associations (PostMedia links) were lost
  on rebuild-from-filesystem: the media sidecar persists `linkedPostIds`, but
  the rebuild never restored them, so galleries rendered empty afterwards.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Media
  alias BDS.Posts.PostMedia
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    temp_dir = Path.join(System.tmp_dir!(), "bds-linkrestore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "LinkRestore", data_path: temp_dir})
    {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{main_language: "en"})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Gallery Post",
        content: "[[gallery]]",
        language: "en"
      })

    source = Path.join(temp_dir, "linked.jpg")
    File.write!(source, "fake jpeg")
    {:ok, media} = Media.import_media(%{project_id: project.id, source_path: source})
    {:ok, _} = Media.link_media_to_post(media.id, post.id)

    %{project: project, post: post, media: media}
  end

  defp link_count(post_id, media_id) do
    Repo.aggregate(
      from(pm in PostMedia, where: pm.post_id == ^post_id and pm.media_id == ^media_id),
      :count
    )
  end

  test "media rebuild-from-filesystem restores PostMedia links from the sidecar", %{
    project: project,
    post: post,
    media: media
  } do
    assert link_count(post.id, media.id) == 1

    # Simulate the DB losing gallery links (e.g. a prior rebuild).
    Repo.delete_all(from pm in PostMedia, where: pm.media_id == ^media.id)
    assert link_count(post.id, media.id) == 0

    assert {:ok, _} = BDS.Media.rebuild_media_from_files(project.id)

    assert link_count(post.id, media.id) == 1
  end

  test "restore is idempotent and does not duplicate existing links", %{
    project: project,
    post: post,
    media: media
  } do
    assert {:ok, _} = BDS.Media.rebuild_media_from_files(project.id)
    assert link_count(post.id, media.id) == 1
  end

  test "rebuild_media_links rebuilds gallery links from sidecars", %{
    project: project,
    post: post,
    media: media
  } do
    # Simulate a project whose junction table was never populated even though
    # the media sidecar references the post (the reported gallery regression).
    Repo.delete_all(from pm in PostMedia, where: pm.media_id == ^media.id)
    assert link_count(post.id, media.id) == 0

    assert {:ok, %{media: 1, links: 1}} = BDS.Media.rebuild_media_links(project.id)

    assert link_count(post.id, media.id) == 1
  end

  test "rebuild_media_links drops stale junction links not present in sidecars", %{
    project: project,
    post: post,
    media: media
  } do
    {:ok, other_post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Unrelated Post",
        content: "no gallery here",
        language: "en"
      })

    # A junction row that drifted from the sidecar: the media is linked to a
    # post its sidecar does not reference. The sidecar is the source of truth,
    # so rebuild must drop this link.
    Repo.insert!(%PostMedia{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      post_id: other_post.id,
      media_id: media.id,
      sort_order: 5,
      created_at: 0
    })

    assert {:ok, %{links: 1}} = BDS.Media.rebuild_media_links(project.id)

    # The real (sidecar-backed) link survives, the drifted link is gone.
    assert link_count(post.id, media.id) == 1
    assert link_count(other_post.id, media.id) == 0
  end
end
