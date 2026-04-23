defmodule BDS.MediaTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-media-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Media", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "import_media copies the binary, creates a sidecar, and persists the row", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Sample",
               alt: "Alt text",
               caption: "Caption",
               author: "Writer",
               language: "en",
               tags: ["alpha"]
             })

    assert media.original_name == "sample.txt"
    assert media.mime_type == "text/plain"
    assert media.size == byte_size("hello media")
    assert media.tags == ["alpha"]
    assert media.file_path =~ ~r/^media\/\d{4}\/\d{2}\/.+\.txt$/
    assert media.sidecar_path == media.file_path <> ".meta"

    assert File.read!(Path.join(temp_dir, media.file_path)) == "hello media"

    sidecar = File.read!(Path.join(temp_dir, media.sidecar_path))
    assert sidecar =~ "id: #{media.id}\n"
    assert sidecar =~ "original_name: sample.txt\n"
    assert sidecar =~ "mime_type: text/plain\n"
    assert sidecar =~ "title: Sample\n"
    assert sidecar =~ "alt: Alt text\n"
    assert sidecar =~ "caption: Caption\n"
    assert sidecar =~ "author: Writer\n"
    assert sidecar =~ "language: en\n"
    assert sidecar =~ "tags:\n  - alpha\n"
  end

  test "update_media rewrites the sidecar metadata", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert {:ok, updated} =
             BDS.Media.update_media(media.id, %{
               title: "Updated",
               alt: "Updated alt",
               tags: ["beta"],
               language: "de"
             })

    assert updated.title == "Updated"
    assert updated.alt == "Updated alt"
    assert updated.tags == ["beta"]
    assert updated.language == "de"

    sidecar = File.read!(Path.join(temp_dir, updated.sidecar_path))
    assert sidecar =~ "title: Updated\n"
    assert sidecar =~ "alt: Updated alt\n"
    assert sidecar =~ "language: de\n"
    assert sidecar =~ "tags:\n  - beta\n"
  end

  test "delete_media removes the binary, sidecar, and database row", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert {:ok, :deleted} = BDS.Media.delete_media(media.id)
    assert Repo.get(BDS.Media.Media, media.id) == nil
    refute File.exists?(Path.join(temp_dir, media.file_path))
    refute File.exists?(Path.join(temp_dir, media.sidecar_path))
  end

  test "rebuild_media_from_files recreates media rows from sidecars", %{project: project, temp_dir: temp_dir} do
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "asset.txt")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, "hello media")

    File.write!(
      sidecar_path,
      [
        "id: media-from-file",
        "original_name: original.txt",
        "mime_type: text/plain",
        "size: 11",
        "width: 0",
        "height: 0",
        "title: Recovered",
        "alt: Recovered alt",
        "caption: Recovered caption",
        "author: Writer",
        "language: en",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "tags:",
        "  - alpha",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, media_items} = BDS.Media.rebuild_media_from_files(project.id)
    assert length(media_items) == 1

    [media] = media_items
    assert media.id == "media-from-file"
    assert media.project_id == project.id
    assert media.filename == "asset.txt"
    assert media.original_name == "original.txt"
    assert media.mime_type == "text/plain"
    assert media.size == 11
    assert media.title == "Recovered"
    assert media.alt == "Recovered alt"
    assert media.caption == "Recovered caption"
    assert media.author == "Writer"
    assert media.language == "en"
    assert media.tags == ["alpha"]
    assert media.file_path == "media/2026/04/asset.txt"
    assert media.sidecar_path == "media/2026/04/asset.txt.meta"
  end
end
