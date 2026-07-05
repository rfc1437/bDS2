defmodule BDS.Desktop.ShellLive.GalleryImportTest do
  @moduledoc """
  Guards the regression where gallery images were imported but never linked to
  the post when AI analysis was unavailable (offline / no local model), leaving
  galleries empty. Linking must happen regardless of AI, matching the old app.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Desktop.ShellLive.GalleryImport
  alias BDS.Posts.PostMedia
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    temp_dir = Path.join(System.tmp_dir!(), "bds-galimport-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "GalImport", data_path: temp_dir})
    {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{main_language: "en"})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Gallery Post",
        content: "[[gallery]]",
        language: "en"
      })

    %{project: project, post: post, temp_dir: temp_dir}
  end

  test "imports link every image to the post even without AI analysis", %{
    project: project,
    post: post,
    temp_dir: temp_dir
  } do
    paths =
      for i <- 1..3 do
        path = Path.join(temp_dir, "img_#{i}.jpg")
        File.write!(path, "fake jpeg #{i}")
        path
      end

    GalleryImport.start(paths, project.id, post.id, "en", 2, self())

    assert_received {:add_images_complete, 3}

    link_count =
      Repo.aggregate(from(pm in PostMedia, where: pm.post_id == ^post.id), :count)

    assert link_count == 3
  end
end
