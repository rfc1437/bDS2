defmodule BDS.MediaTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-media-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Media", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "import_media copies the binary, creates a sidecar, and persists the row", %{
    project: project,
    temp_dir: temp_dir
  } do
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
    assert sidecar =~ "---\n"
    assert sidecar =~ "id: #{media.id}\n"
    assert sidecar =~ "originalName: \"sample.txt\"\n"
    assert sidecar =~ "mimeType: text/plain\n"
    assert sidecar =~ "title: \"Sample\"\n"
    assert sidecar =~ "alt: \"Alt text\"\n"
    assert sidecar =~ "caption: \"Caption\"\n"
    assert sidecar =~ "author: \"Writer\"\n"
    assert sidecar =~ "language: en\n"
    assert sidecar =~ "tags: [\"alpha\"]\n"
    assert sidecar =~ "linkedPostIds: []\n"
    assert sidecar =~ ~r/createdAt: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\n/
    assert sidecar =~ ~r/updatedAt: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\n/
    assert String.ends_with?(sidecar, "\n---")
    refute File.exists?(Path.join(temp_dir, media.sidecar_path <> ".tmp"))
  end

  test "update_media rewrites the sidecar metadata", %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

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
    assert sidecar =~ "title: \"Updated\"\n"
    assert sidecar =~ "alt: \"Updated alt\"\n"
    assert sidecar =~ "language: de\n"
    assert sidecar =~ "tags: [\"beta\"]\n"
  end

  test "delete_media removes the binary, sidecar, and database row", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

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

  test "replace_media_file copies the new file over the path, updates the row, and regenerates thumbnails synchronously",
       %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "original.jpg")
    File.write!(source_path, Image.new!(4, 4, color: [255, 0, 0]) |> Image.write!(:memory, suffix: ".jpg"))

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert media.width == 4
    assert media.height == 4

    thumbnail_paths = BDS.Media.thumbnail_paths(media)

    # Delete thumbnails so their presence after the replace proves regeneration ran.
    Enum.each(Map.values(thumbnail_paths), fn path ->
      File.rm!(Path.join(temp_dir, path))
    end)

    replacement_path = Path.join(temp_dir, "replacement.jpg")
    File.write!(replacement_path, Image.new!(6, 8, color: [0, 0, 255]) |> Image.write!(:memory, suffix: ".jpg"))
    replacement_binary = File.read!(replacement_path)

    assert {:ok, updated} = BDS.Media.replace_media_file(media.id, replacement_path)

    refute updated.checksum == media.checksum
    assert updated.width == 6
    assert updated.height == 8
    assert updated.size == byte_size(replacement_binary)

    # New file content is on disk at the same path.
    assert File.read!(Path.join(temp_dir, updated.file_path)) == replacement_binary

    # Thumbnails were regenerated synchronously (present immediately, no backup left behind).
    Enum.each(Map.values(BDS.Media.thumbnail_paths(updated)), fn path ->
      assert File.exists?(Path.join(temp_dir, path))
    end)

    refute File.exists?(Path.join(temp_dir, updated.file_path) <> ".bak")
  end

  test "replace_media_file is a no-op when the new file matches the current checksum", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "same.jpg")
    File.write!(source_path, Image.new!(4, 4, color: [255, 0, 0]) |> Image.write!(:memory, suffix: ".jpg"))

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    # First replace establishes a stored checksum (import does not compute one).
    new_path = Path.join(temp_dir, "blue.jpg")
    File.write!(new_path, Image.new!(6, 8, color: [0, 0, 255]) |> Image.write!(:memory, suffix: ".jpg"))

    assert {:ok, updated} = BDS.Media.replace_media_file(media.id, new_path)
    refute is_nil(updated.checksum)

    # Replacing with the identical file is a no-op.
    identical_path = Path.join(temp_dir, "blue_copy.jpg")
    File.cp!(new_path, identical_path)

    assert {:ok, nil} = BDS.Media.replace_media_file(media.id, identical_path)
  end

  test "replace_media_file returns {:error, :not_found} for an unknown media id", %{
    temp_dir: temp_dir
  } do
    replacement_path = Path.join(temp_dir, "orphan.jpg")
    File.write!(replacement_path, Image.new!(4, 4, color: [0, 255, 0]) |> Image.write!(:memory, suffix: ".jpg"))

    assert {:error, :not_found} = BDS.Media.replace_media_file("does-not-exist", replacement_path)
  end

  test "deleting a post rewrites linked media sidecars to remove that post id", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Linked Post",
               content: "Body"
             })

    now = BDS.Persistence.now_ms()

    Repo.insert_all("post_media", [
      %{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        post_id: post.id,
        media_id: media.id,
        sort_order: 0,
        created_at: now
      }
    ])

    assert {:ok, _updated_media} = BDS.Media.update_media(media.id, %{})

    sidecar_before = File.read!(Path.join(temp_dir, media.sidecar_path))
    assert sidecar_before =~ "linkedPostIds: [\"#{post.id}\"]\n"

    assert {:ok, :deleted} = BDS.Posts.delete_post(post.id)

    refute Repo.exists?(from row in "post_media", where: field(row, :media_id) == ^media.id)

    sidecar_after = File.read!(Path.join(temp_dir, media.sidecar_path))
    assert sidecar_after =~ "linkedPostIds: []\n"
  end

  test "rebuild_media_from_files recreates media rows from sidecars", %{
    project: project,
    temp_dir: temp_dir
  } do
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "asset.jpg")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, tiny_jpeg_binary())

    File.write!(
      sidecar_path,
      [
        "id: media-from-file",
        "originalName: original.jpg",
        "mimeType: image/jpeg",
        "size: #{byte_size(tiny_jpeg_binary())}",
        "width: 3",
        "height: 2",
        "title: Recovered",
        "alt: Recovered alt",
        "caption: Recovered caption",
        "author: Writer",
        "language: en",
        "createdAt: 2024-03-30T21:20:00.000Z",
        "updatedAt: 2024-03-31T21:20:00.000Z",
        "linkedPostIds:",
        "  - post-a",
        "tags:",
        "  - alpha",
        ""
      ]
      |> Enum.join("\n")
    )

    File.write!(
      binary_path <> ".de.meta",
      [
        "translationFor: media-from-file",
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
    assert media.size == byte_size(tiny_jpeg_binary())
    assert media.title == "Recovered"
    assert media.alt == "Recovered alt"
    assert media.caption == "Recovered caption"
    assert media.author == "Writer"
    assert media.language == "en"
    assert media.tags == ["alpha"]
    assert media.created_at == 1_711_833_600_000
    assert media.updated_at == 1_711_920_000_000
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
      refute File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "rebuild_media_from_files parses inline empty tag arrays", %{
    project: project,
    temp_dir: temp_dir
  } do
    media_dir = Path.join([temp_dir, "media", "2002", "11"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "muehle.jpg")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, tiny_jpeg_binary())

    File.write!(
      sidecar_path,
      [
        "id: 23c69669-678d-4b0b-bb10-c4c31bd427d1",
        "originalName: muehle.jpg",
        "mimeType: image/jpeg",
        "size: #{byte_size(tiny_jpeg_binary())}",
        "width: 3",
        "height: 2",
        "title: Beitrag ohne Titel",
        "alt: Ein grüner Mühlenbau mit Windmühlen in einem goldgelben Feld",
        "caption: Ein friedlicher Blick auf eine alte Mühle und die Weizenernte unter einem strahlend blauen Himmel.",
        "createdAt: '2002-11-17T00:00:00.000Z'",
        "updatedAt: '2026-03-18T15:31:10.146Z'",
        "tags: []",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, [media]} = BDS.Media.rebuild_media_from_files(project.id)
    assert media.id == "23c69669-678d-4b0b-bb10-c4c31bd427d1"
    assert media.original_name == "muehle.jpg"
    assert media.tags == []
    assert media.created_at == 1_037_491_200_000
    assert media.updated_at == 1_773_847_870_146
  end

  test "rebuild_media_from_files does not regenerate thumbnails", %{
    project: project,
    temp_dir: temp_dir
  } do
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "asset.jpg")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, tiny_jpeg_binary())

    File.write!(
      sidecar_path,
      [
        "id: media-without-thumbnails",
        "originalName: original.jpg",
        "mimeType: image/jpeg",
        "size: #{byte_size(tiny_jpeg_binary())}",
        "width: 3",
        "height: 2",
        "title: Recovered",
        "createdAt: 2024-03-30T21:20:00.000Z",
        "updatedAt: 2024-03-31T21:20:00.000Z",
        "tags:",
        "  - alpha",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, [media]} = BDS.Media.rebuild_media_from_files(project.id)

    Enum.each(Map.values(BDS.Media.thumbnail_paths(media)), fn path ->
      refute File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "rebuild_media_from_files returns an error for unreadable sidecars", %{
    project: project,
    temp_dir: temp_dir
  } do
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)

    binary_path = Path.join(media_dir, "asset.jpg")
    sidecar_path = binary_path <> ".meta"

    File.write!(binary_path, tiny_jpeg_binary())
    File.mkdir_p!(sidecar_path)

    assert {:error, {:read_sidecar, ^sidecar_path, :eisdir}} =
             BDS.Media.rebuild_media_from_files(project.id)
  end

  test "import_media generates the four thumbnail files in bucketed thumbnail paths", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, tiny_jpeg_binary())

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    thumbnail_paths = BDS.Media.thumbnail_paths(media)

    assert thumbnail_paths.small ==
             "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-small.webp"

    assert thumbnail_paths.medium ==
             "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-medium.webp"

    assert thumbnail_paths.large ==
             "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-large.webp"

    assert thumbnail_paths.ai == "thumbnails/#{String.slice(media.id, 0, 2)}/#{media.id}-ai.jpg"

    Enum.each(Map.values(thumbnail_paths), fn path ->
      assert File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "import_media extracts image dimensions and writes real encoded thumbnails", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, tiny_jpeg_binary())

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert media.mime_type == "image/jpeg"
    assert media.width == 3
    assert media.height == 2

    thumbnail_paths = BDS.Media.thumbnail_paths(media)

    small = Image.open!(Path.join(temp_dir, thumbnail_paths.small))
    medium = Image.open!(Path.join(temp_dir, thumbnail_paths.medium))
    large = Image.open!(Path.join(temp_dir, thumbnail_paths.large))
    ai = Image.open!(Path.join(temp_dir, thumbnail_paths.ai))

    assert Image.width(small) == 3
    assert Image.height(small) == 2
    assert Image.width(medium) == 3
    assert Image.height(medium) == 2
    assert Image.width(large) == 3
    assert Image.height(large) == 2
    assert Image.width(ai) == 448
    assert Image.height(ai) == 448

    assert Path.extname(thumbnail_paths.small) == ".webp"
    assert Path.extname(thumbnail_paths.medium) == ".webp"
    assert Path.extname(thumbnail_paths.large) == ".webp"
    assert Path.extname(thumbnail_paths.ai) == ".jpg"
  end

  test "import_media keeps raw header dimensions but autorotates thumbnails from EXIF orientation",
       %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "rotated.jpg")
    write_oriented_jpeg!(source_path, 6)

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert media.width == 2
    assert media.height == 3

    thumbnail_path = Path.join(temp_dir, BDS.Media.thumbnail_paths(media).small)
    actual_thumbnail = Image.open!(thumbnail_path)
    expected_thumbnail = expected_small_thumbnail(source_path)

    assert Image.width(actual_thumbnail) == 3
    assert Image.height(actual_thumbnail) == 2
    assert_images_match!(actual_thumbnail, expected_thumbnail)
  end

  test "regenerate_thumbnails recreates thumbnail files for an existing image media item", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, tiny_jpeg_binary())

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    thumbnail_paths = BDS.Media.thumbnail_paths(media)
    File.rm!(Path.join(temp_dir, thumbnail_paths.small))
    File.rm!(Path.join(temp_dir, thumbnail_paths.medium))

    assert {:ok, regenerated} = BDS.Media.regenerate_thumbnails(media.id)
    assert regenerated.id == media.id

    Enum.each(Map.values(thumbnail_paths), fn path ->
      assert File.exists?(Path.join(temp_dir, path))
    end)
  end

  test "import_media generates thumbnails for png and webp sources", %{
    project: project,
    temp_dir: temp_dir
  } do
    Enum.each([{".png", "image/png"}, {".webp", "image/webp"}], fn {extension, mime_type} ->
      source_path = Path.join(temp_dir, "sample#{extension}")
      File.write!(source_path, sample_image_binary(extension))

      assert {:ok, media} =
               BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

      assert media.mime_type == mime_type
      assert media.width == 2
      assert media.height == 3

      Enum.each(Map.values(BDS.Media.thumbnail_paths(media)), fn path ->
        assert File.exists?(Path.join(temp_dir, path))
      end)
    end)
  end

  test "import_media detects supported TIFF, BMP, HEIC, and HEIF extensions", %{
    project: project,
    temp_dir: temp_dir
  } do
    Enum.each(
      [
        {"asset.tif", "image/tiff"},
        {"asset.tiff", "image/tiff"},
        {"asset.bmp", "image/bmp"},
        {"asset.heic", "image/heic"},
        {"asset.heif", "image/heif"}
      ],
      fn {file_name, mime_type} ->
        source_path = Path.join(temp_dir, file_name)
        File.write!(source_path, "placeholder")

        assert {:ok, media} =
                 BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

        assert media.mime_type == mime_type
        assert media.width == nil
        assert media.height == nil
      end
    )
  end

  test "upsert_media_translation persists the row and writes a translated sidecar next to the binary",
       %{project: project, temp_dir: temp_dir} do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

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
    assert contents =~ "---\n"
    assert contents =~ "translationFor: #{media.id}\n"
    assert contents =~ "language: de\n"
    assert contents =~ "title: \"Titel\"\n"
    assert contents =~ "alt: \"Alt text\"\n"
    assert contents =~ "caption: \"Bildunterschrift\"\n---"
  end

  test "UniqueMediaTranslation: a media has at most one translation per language", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    assert {:ok, first} =
             BDS.Media.upsert_media_translation(media.id, "de", %{title: "Titel"})

    # Re-upserting the same language updates the existing row instead of adding a second.
    assert {:ok, second} =
             BDS.Media.upsert_media_translation(media.id, "de", %{title: "Geändert"})

    assert second.id == first.id

    assert [persisted] =
             BDS.Media.Translation
             |> where([t], t.translation_for == ^media.id and t.language == "de")
             |> Repo.all()

    assert persisted.title == "Geändert"

    # A direct insert of a distinct row with the same (media, language) is rejected by the
    # unique constraint backing the invariant.
    now = BDS.Persistence.now_ms()

    duplicate =
      BDS.Media.Translation.changeset(%BDS.Media.Translation{}, %{
        id: Ecto.UUID.generate(),
        project_id: media.project_id,
        translation_for: media.id,
        language: "de",
        title: "Duplicate",
        created_at: now,
        updated_at: now
      })

    assert {:error, changeset} = Repo.insert(duplicate)
    assert %{language: ["has already been taken"]} = errors_on(changeset)
  end

  test "SidecarRoundtrip: writing then parsing a sidecar yields matching DB metadata", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "roundtrip.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Roundtrip Title",
               alt: "Roundtrip Alt",
               caption: "Roundtrip Caption",
               author: "Tester",
               language: "en",
               tags: ["alpha", "beta"]
             })

    sidecar_path = Path.join(temp_dir, media.sidecar_path)
    {:ok, contents} = File.read(sidecar_path)
    {:ok, parsed} = BDS.Sidecar.parse_document(contents)

    assert parsed["title"] == media.title
    assert parsed["alt"] == media.alt
    assert parsed["caption"] == media.caption
    assert parsed["tags"] == media.tags
    assert parsed["id"] == media.id
    assert parsed["originalName"] == media.original_name
    assert parsed["mimeType"] == media.mime_type
    assert parsed["size"] == media.size
    assert parsed["author"] == media.author
    assert parsed["language"] == media.language
    assert parsed["createdAt"] == media.created_at
    assert parsed["updatedAt"] == media.updated_at
  end

  test "SidecarRoundtrip: conditional fields are absent from parsed sidecar when nil", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "minimal.txt")
    File.write!(source_path, "hello media")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path
             })

    assert media.title == nil
    assert media.alt == nil
    assert media.caption == nil
    assert media.author == nil
    assert media.language == nil

    sidecar_path = Path.join(temp_dir, media.sidecar_path)
    {:ok, contents} = File.read(sidecar_path)
    {:ok, parsed} = BDS.Sidecar.parse_document(contents)

    refute Map.has_key?(parsed, "title")
    refute Map.has_key?(parsed, "alt")
    refute Map.has_key?(parsed, "caption")
    refute Map.has_key?(parsed, "author")
    refute Map.has_key?(parsed, "language")

    assert Map.has_key?(parsed, "id")
    assert Map.has_key?(parsed, "originalName")
    assert Map.has_key?(parsed, "mimeType")
    assert Map.has_key?(parsed, "size")
    assert Map.has_key?(parsed, "tags")
    assert Map.has_key?(parsed, "createdAt")
    assert Map.has_key?(parsed, "updatedAt")
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp tiny_jpeg_binary do
    Image.new!(3, 2, color: [255, 0, 0])
    |> Image.write!(:memory, suffix: ".jpg", quality: 85)
  end

  defp sample_image_binary(extension) do
    sample_svg_binary()
    |> Image.from_svg!()
    |> Image.write!(:memory, suffix: extension, quality: 85)
  end

  defp sample_svg_binary do
    """
    <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"3\">
      <rect width=\"1\" height=\"1\" x=\"0\" y=\"0\" fill=\"#ff0000\"/>
      <rect width=\"1\" height=\"1\" x=\"1\" y=\"0\" fill=\"#00ff00\"/>
      <rect width=\"1\" height=\"1\" x=\"0\" y=\"1\" fill=\"#0000ff\"/>
      <rect width=\"1\" height=\"1\" x=\"1\" y=\"1\" fill=\"#ffff00\"/>
      <rect width=\"1\" height=\"1\" x=\"0\" y=\"2\" fill=\"#00ffff\"/>
      <rect width=\"1\" height=\"1\" x=\"1\" y=\"2\" fill=\"#ff00ff\"/>
    </svg>
    """
  end

  defp write_oriented_jpeg!(path, orientation) do
    image = sample_image_binary(".jpg") |> Image.open!()

    {:ok, oriented_image} =
      Vix.Vips.Image.mutate(image, fn mutable_image ->
        :ok = Vix.Vips.MutableImage.update(mutable_image, "orientation", orientation)
      end)

    Image.write!(oriented_image, path, quality: 85)
  end

  defp expected_small_thumbnail(source_path) do
    source_path
    |> Image.open!()
    |> Image.autorotate!()
    |> Image.thumbnail!("150x150", fit: :contain, resize: :down, autorotate: false)
    |> Image.write!(:memory, suffix: ".webp", quality: 80, strip_metadata: true)
    |> Image.open!()
  end

  defp assert_images_match!(left, right) do
    assert Image.shape(left) == Image.shape(right)

    assert {:ok, score, _difference_image} = Image.compare(left, right)
    assert score <= 0.0
  end
end
