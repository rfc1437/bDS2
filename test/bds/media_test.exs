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

    assert {:ok, _translation} =
             BDS.Media.upsert_media_translation(media.id, "de", %{
               title: "Titel",
               alt: "Alt",
               caption: "Beschriftung"
             })

    thumbnail_paths = BDS.Media.thumbnail_paths(media)

    assert {:ok, :deleted} = BDS.Media.delete_media(media.id)
    assert Repo.get(BDS.Media.Media, media.id) == nil
    assert Repo.all(BDS.Media.Translation) == []
    refute File.exists?(Path.join(temp_dir, media.file_path))
    refute File.exists?(Path.join(temp_dir, media.sidecar_path))
    refute File.exists?(Path.join(temp_dir, media.file_path <> ".de.meta"))

    Enum.each(Map.values(thumbnail_paths), fn path ->
      refute File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "rebuild_media_from_files recreates media rows from sidecars", %{project: project, temp_dir: temp_dir} do
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "asset.jpg")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, "fake-jpeg")

    File.write!(
      sidecar_path,
      [
        "id: media-from-file",
        "original_name: original.jpg",
        "mime_type: image/jpeg",
        "size: 9",
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

    File.write!(
      binary_path <> ".de.meta",
      [
        "translation_for: media-from-file",
        "language: de",
        "title: Titel",
        "alt: Alt text",
        "caption: Bildunterschrift",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, media_items} = BDS.Media.rebuild_media_from_files(project.id)
    assert length(media_items) == 1

    [media] = media_items
    assert media.id == "media-from-file"
    assert media.project_id == project.id
    assert media.filename == "asset.jpg"
    assert media.original_name == "original.jpg"
    assert media.mime_type == "image/jpeg"
    assert media.size == 9
    assert media.title == "Recovered"
    assert media.alt == "Recovered alt"
    assert media.caption == "Recovered caption"
    assert media.author == "Writer"
    assert media.language == "en"
    assert media.tags == ["alpha"]
    assert media.file_path == "media/2026/04/asset.jpg"
    assert media.sidecar_path == "media/2026/04/asset.jpg.meta"

    [translation] = Repo.all(BDS.Media.Translation)
    assert translation.translation_for == "media-from-file"
    assert translation.language == "de"
    assert translation.title == "Titel"
    assert translation.alt == "Alt text"
    assert translation.caption == "Bildunterschrift"

    thumbnail_paths = BDS.Media.thumbnail_paths(media)

    Enum.each(Map.values(thumbnail_paths), fn path ->
      assert File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "import_media generates the four thumbnail files in bucketed thumbnail paths", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, "fake-jpeg")

    assert {:ok, media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    thumbnail_paths = BDS.Media.thumbnail_paths(media)
    assert thumbnail_paths.small == "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-small.webp"
    assert thumbnail_paths.medium == "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-medium.webp"
    assert thumbnail_paths.large == "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-large.webp"
    assert thumbnail_paths.ai == "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-ai.jpg"

    Enum.each(Map.values(thumbnail_paths), fn path ->
      assert File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "upsert_media_translation persists the row and writes a translated sidecar next to the binary", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert {:ok, translation} =
             BDS.Media.upsert_media_translation(media.id, "de", %{
               title: "Titel",
               alt: "Alt text",
               caption: "Bildunterschrift"
             })

    assert translation.translation_for == media.id
    assert translation.language == "de"
    assert translation.title == "Titel"

    translated_sidecar_path = Path.join(temp_dir, media.file_path <> ".de.meta")
    contents = File.read!(translated_sidecar_path)
    assert contents =~ "translation_for: #{media.id}\n"
    assert contents =~ "language: de\n"
    assert contents =~ "title: Titel\n"
    assert contents =~ "alt: Alt text\n"
    assert contents =~ "caption: Bildunterschrift\n"
  end
end
