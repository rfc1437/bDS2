defmodule BDS.CSM009ThumbnailErrorHandlingTest do
  use ExUnit.Case, async: false

  alias BDS.Media.Thumbnails
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-csm009-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM009", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "ensure_thumbnails returns {:error, _} for a corrupt image instead of crashing", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "corrupt.jpg")
    File.write!(source_path, "not a real image")

    {:ok, media} =
      BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert media.mime_type == "image/jpeg"

    Enum.each(Map.values(Thumbnails.thumbnail_paths(media)), fn path ->
      File.rm(Path.join(temp_dir, path))
    end)

    result = Thumbnails.ensure_thumbnails(project, media)
    assert {:error, _reason} = result
  end

  test "ensure_thumbnails returns :ok for non-image media", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "readme.txt")
    File.write!(source_path, "just text")

    {:ok, media} =
      BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert Thumbnails.ensure_thumbnails(project, media) == :ok
  end

  test "ensure_thumbnails returns {:error, _} when source file is missing", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, tiny_jpeg_binary())

    {:ok, media} =
      BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    File.rm!(Path.join(temp_dir, media.file_path))

    result = Thumbnails.ensure_thumbnails(project, media)
    assert {:error, _reason} = result
  end

  test "regenerate_thumbnails returns {:error, _} for corrupt source", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "corrupt2.jpg")
    File.write!(source_path, "not valid jpeg data")

    {:ok, media} =
      BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    Enum.each(Map.values(Thumbnails.thumbnail_paths(media)), fn path ->
      File.rm(Path.join(temp_dir, path))
    end)

    File.write!(Path.join(temp_dir, media.file_path), "not valid jpeg data")

    result = Thumbnails.regenerate_thumbnails(media.id)
    assert {:error, _reason} = result
  end

  test "regenerate_missing_thumbnails counts failures without crashing", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "good.jpg")
    File.write!(source_path, tiny_jpeg_binary())
    {:ok, good_media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    corrupt_path = Path.join(temp_dir, "bad.jpg")
    File.write!(corrupt_path, "corrupt data")
    {:ok, bad_media} = BDS.Media.import_media(%{project_id: project.id, source_path: corrupt_path})

    Enum.each(Map.values(Thumbnails.thumbnail_paths(good_media)), fn path ->
      File.rm(Path.join(temp_dir, path))
    end)

    Enum.each(Map.values(Thumbnails.thumbnail_paths(bad_media)), fn path ->
      File.rm(Path.join(temp_dir, path))
    end)

    File.write!(Path.join(temp_dir, bad_media.file_path), "corrupt data")

    result = Thumbnails.regenerate_missing_thumbnails(project.id)
    assert result.failed >= 1
    assert result.processed >= 2
  end

  test "import_media succeeds even when thumbnail generation fails for corrupt image", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "bad_import.jpg")
    File.write!(source_path, "not a real image at all")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert media.mime_type == "image/jpeg"
    assert Repo.get(BDS.Media.Media, media.id) != nil
  end

  defp tiny_jpeg_binary do
    Image.new!(3, 2, color: [255, 0, 0])
    |> Image.write!(:memory, suffix: ".jpg", quality: 85)
  end
end
