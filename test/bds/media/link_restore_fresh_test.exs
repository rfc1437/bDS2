defmodule BDS.Media.LinkRestoreFreshTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Media
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.PostMedia
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    temp_dir = Path.join(System.tmp_dir!(), "bds-freshlink-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Fresh", data_path: temp_dir})
    {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{main_language: "en"})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Gallery Post",
        content: "[[gallery]]",
        language: "en"
      })

    source = Path.join(temp_dir, "fresh.jpg")
    File.write!(source, "fake jpeg")
    {:ok, media} = Media.import_media(%{project_id: project.id, source_path: source})
    {:ok, _} = Media.link_media_to_post(media.id, post.id)

    %{project: project, post: post, media: media}
  end

  test "fresh media rebuild (media record gone, only files on disk) restores links", %{
    project: project,
    post: post,
    media: media
  } do
    # Sidecar on disk should carry the link.
    sidecar_path = Path.join(project.data_path, media.sidecar_path)
    assert File.exists?(sidecar_path)
    contents = File.read!(sidecar_path)
    assert contents =~ "linkedPostIds"
    assert contents =~ post.id

    # Simulate a fresh DB: drop the media record AND its links entirely.
    Repo.delete_all(from pm in PostMedia, where: pm.media_id == ^media.id)
    Repo.delete_all(from m in MediaRecord, where: m.id == ^media.id)
    assert Repo.aggregate(from(m in MediaRecord, where: m.id == ^media.id), :count) == 0

    assert {:ok, _} = BDS.Media.rebuild_media_from_files(project.id)

    # Media re-inserted from sidecar.
    assert Repo.aggregate(from(m in MediaRecord, where: m.project_id == ^project.id), :count) == 1

    # Link restored so the post's media list is populated again.
    assert Repo.aggregate(from(pm in PostMedia, where: pm.post_id == ^post.id), :count) == 1
  end
end
