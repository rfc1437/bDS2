defmodule BDS.Media do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Media.Translation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Sidecar

  def import_media(attrs) do
    project = Projects.get_project!(attr(attrs, :project_id))
    source_path = attr(attrs, :source_path)
    original_name = Path.basename(source_path)
    mime_type = detect_mime(original_name)
    {width, height} = image_dimensions(source_path, mime_type)
    now = System.system_time(:second)
    file_name = Ecto.UUID.generate() <> Path.extname(original_name)
    file_path = media_file_path(file_name, now)
    sidecar_path = file_path <> ".meta"
    destination = Path.join(Projects.project_data_dir(project), file_path)
    stat = File.stat!(source_path)

    Repo.transaction(fn ->
      media =
        %Media{}
        |> Media.changeset(%{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          filename: file_name,
          original_name: original_name,
          mime_type: mime_type,
          size: stat.size,
          width: attr(attrs, :width) || width,
          height: attr(attrs, :height) || height,
          title: attr(attrs, :title),
          alt: attr(attrs, :alt),
          caption: attr(attrs, :caption),
          author: attr(attrs, :author),
          language: attr(attrs, :language),
          file_path: file_path,
          sidecar_path: sidecar_path,
          checksum: attr(attrs, :checksum),
          tags: attr(attrs, :tags) || [],
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()

      :ok = File.mkdir_p(Path.dirname(destination))
      :ok = File.cp(source_path, destination)
      :ok = write_sidecar(project, media)
      :ok = ensure_thumbnails(project, media)
      :ok = Search.sync_media(media)
      media
    end)
    |> case do
      {:ok, media} -> {:ok, media}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_media(media_id, attrs) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        updates =
          %{}
          |> maybe_put(:title, attr(attrs, :title))
          |> maybe_put(:alt, attr(attrs, :alt))
          |> maybe_put(:caption, attr(attrs, :caption))
          |> maybe_put(:author, attr(attrs, :author))
          |> maybe_put(:language, attr(attrs, :language))
          |> maybe_put(:tags, attr(attrs, :tags))
          |> maybe_put(:width, attr(attrs, :width))
          |> maybe_put(:height, attr(attrs, :height))
          |> Map.put(:updated_at, System.system_time(:second))

        project = Projects.get_project!(media.project_id)

        Repo.transaction(fn ->
          updated_media =
            media
            |> Media.changeset(updates)
            |> Repo.update!()

          :ok = write_sidecar(project, updated_media)
          :ok = Search.sync_media(updated_media)
          updated_media
        end)
        |> case do
          {:ok, updated_media} -> {:ok, updated_media}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def delete_media(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        translations =
          Repo.all(
            from translation in Translation, where: translation.translation_for == ^media.id
          )

        delete_file_if_present(media.project_id, media.file_path)
        delete_file_if_present(media.project_id, media.sidecar_path)
        delete_thumbnail_files(media.project_id, media)

        Enum.each(translations, fn translation ->
          delete_file_if_present(
            media.project_id,
            translation_sidecar_path(media, translation.language)
          )

          Repo.delete!(translation)
        end)

        Repo.delete!(media)
        :ok = Search.delete_media(media.id)
        {:ok, :deleted}
    end
  end

  def upsert_media_translation(media_id, language, attrs) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        now = System.system_time(:second)

        translation =
          Repo.get_by(Translation, translation_for: media.id, language: language) ||
            %Translation{id: Ecto.UUID.generate(), created_at: now}

        translation_attrs = %{
          id: translation.id,
          project_id: media.project_id,
          translation_for: media.id,
          language: language,
          title: attr(attrs, :title),
          alt: attr(attrs, :alt),
          caption: attr(attrs, :caption),
          created_at: translation.created_at || now,
          updated_at: now
        }

        Repo.transaction(fn ->
          updated_translation =
            translation
            |> Translation.changeset(translation_attrs)
            |> Repo.insert_or_update!()

          :ok = write_translation_sidecar(project, media, updated_translation)
          :ok = Search.sync_media(media.id)
          updated_translation
        end)
        |> case do
          {:ok, updated_translation} -> {:ok, updated_translation}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def thumbnail_paths(%Media{id: id}) do
    prefix = String.slice(id, 0, 2)

    %{
      small: Path.join(["thumbnails", prefix, "#{id}-small.webp"]),
      medium: Path.join(["thumbnails", prefix, "#{id}-medium.webp"]),
      large: Path.join(["thumbnails", prefix, "#{id}-large.webp"]),
      ai: Path.join(["thumbnails", prefix, "#{id}-ai.jpg"])
    }
  end

  def regenerate_thumbnails(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        :ok = ensure_thumbnails(project, media)
        {:ok, media}
    end
  end

  def rebuild_media_from_files(project_id) do
    project = Projects.get_project!(project_id)

    canonical_sidecars =
      project
      |> Projects.project_data_dir()
      |> Path.join("media")
      |> list_matching_files("*.meta")
      |> Enum.filter(&canonical_sidecar?/1)
      |> Enum.filter(&binary_exists_for_sidecar?/1)

    media_items = Enum.map(canonical_sidecars, &upsert_media_from_sidecar(project, &1))

    canonical_media_by_binary_path =
      Map.new(media_items, fn media ->
        {Path.join(Projects.project_data_dir(project), media.file_path), media}
      end)

    project
    |> Projects.project_data_dir()
    |> Path.join("media")
    |> list_matching_files("*.meta")
    |> Enum.filter(&translation_sidecar?/1)
    |> Enum.each(&upsert_translation_from_sidecar(project, canonical_media_by_binary_path, &1))

    {:ok, media_items}
  end

  defp upsert_media_from_sidecar(project, sidecar_path) do
    {:ok, fields} = sidecar_path |> File.read!() |> Sidecar.parse_document()
    relative_sidecar_path = Path.relative_to(sidecar_path, Projects.project_data_dir(project))
    relative_file_path = String.trim_trailing(relative_sidecar_path, ".meta")
    filename = Path.basename(relative_file_path)
    now = System.system_time(:second)

    attrs = %{
      id: Map.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project.id,
      filename: filename,
      original_name: Map.get(fields, "original_name") || filename,
      mime_type: Map.get(fields, "mime_type") || detect_mime(filename),
      size: Map.get(fields, "size", 0),
      width: blank_to_nil(Map.get(fields, "width")),
      height: blank_to_nil(Map.get(fields, "height")),
      title: Map.get(fields, "title"),
      alt: Map.get(fields, "alt"),
      caption: Map.get(fields, "caption"),
      author: Map.get(fields, "author"),
      language: Map.get(fields, "language"),
      file_path: relative_file_path,
      sidecar_path: relative_sidecar_path,
      checksum: nil,
      tags: Map.get(fields, "tags", []),
      created_at: Map.get(fields, "created_at", now),
      updated_at: Map.get(fields, "updated_at", now)
    }

    media =
      Repo.get(Media, attrs.id) ||
        Repo.get_by(Media, project_id: project.id, file_path: relative_file_path) || %Media{}

    media
    |> Media.changeset(attrs)
    |> Repo.insert_or_update!()
    |> tap(fn reloaded_media -> ensure_thumbnails(project, reloaded_media) end)
    |> tap(&Search.sync_media/1)
  end

  defp write_sidecar(project, media) do
    path = Path.join(Projects.project_data_dir(project), media.sidecar_path)
    :ok = File.mkdir_p(Path.dirname(path))

    atomic_write(
      path,
      Sidecar.serialize_document([
        {:id, media.id},
        {:original_name, media.original_name},
        {:mime_type, media.mime_type},
        {:size, media.size},
        {:width, media.width},
        {:height, media.height},
        {:title, media.title},
        {:alt, media.alt},
        {:caption, media.caption},
        {:author, media.author},
        {:language, media.language},
        {:created_at, media.created_at},
        {:updated_at, media.updated_at},
        {:tags, media.tags || []}
      ])
    )
  end

  defp write_translation_sidecar(project, media, translation) do
    path =
      Path.join(
        Projects.project_data_dir(project),
        translation_sidecar_path(media, translation.language)
      )

    :ok = File.mkdir_p(Path.dirname(path))

    atomic_write(
      path,
      Sidecar.serialize_document([
        {:translation_for, media.id},
        {:language, translation.language},
        {:title, translation.title},
        {:alt, translation.alt},
        {:caption, translation.caption}
      ])
    )
  end

  defp upsert_translation_from_sidecar(project, canonical_media_by_binary_path, sidecar_path) do
    binary_path = binary_path_for_translation_sidecar(sidecar_path)

    case Map.get(canonical_media_by_binary_path, binary_path) do
      nil ->
        :skip

      media ->
        {:ok, fields} = sidecar_path |> File.read!() |> Sidecar.parse_document()
        now = System.system_time(:second)
        language = Map.fetch!(fields, "language")

        translation =
          Repo.get_by(Translation, translation_for: media.id, language: language) ||
            %Translation{id: Ecto.UUID.generate(), created_at: now}

        translation
        |> Translation.changeset(%{
          id: translation.id,
          project_id: project.id,
          translation_for: media.id,
          language: language,
          title: Map.get(fields, "title"),
          alt: Map.get(fields, "alt"),
          caption: Map.get(fields, "caption"),
          created_at: translation.created_at || now,
          updated_at: now
        })
        |> Repo.insert_or_update!()

        :ok = Search.sync_media(media.id)
    end
  end

  defp ensure_thumbnails(project, media) do
    if image_mime?(media.mime_type) do
      source_path = Path.join(Projects.project_data_dir(project), media.file_path)

      case Image.open(source_path) do
        {:ok, image} ->
          image
          |> Image.autorotate!()
          |> write_all_thumbnails(project, media)

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  defp write_all_thumbnails(image, project, media) do
    thumbnail_paths(media)
    |> Enum.each(fn {size, relative_path} ->
      destination = Path.join(Projects.project_data_dir(project), relative_path)
      :ok = File.mkdir_p(Path.dirname(destination))

      image
      |> render_thumbnail(size)
      |> write_thumbnail(destination, size)
    end)

    :ok
  end

  defp render_thumbnail(image, :small), do: bounded_thumbnail(image, 150, 150)
  defp render_thumbnail(image, :medium), do: bounded_thumbnail(image, 400, 400)
  defp render_thumbnail(image, :large), do: bounded_thumbnail(image, 800, 800)

  defp render_thumbnail(image, :ai) do
    image
    |> Image.thumbnail!("448x448", fit: :contain, resize: :both, autorotate: false)
    |> Image.embed!(448, 448, x: :center, y: :center, background_color: :black)
  end

  defp bounded_thumbnail(image, width, height) do
    Image.thumbnail!(image, "#{width}x#{height}", fit: :contain, resize: :down, autorotate: false)
  end

  defp write_thumbnail(image, destination, :ai) do
    flattened = Image.flatten!(image, background_color: :black)
    Image.write!(flattened, destination, quality: 85, strip_metadata: true)
    :ok
  end

  defp write_thumbnail(image, destination, _size) do
    Image.write!(image, destination, quality: 80, strip_metadata: true)
    :ok
  end

  defp delete_thumbnail_files(project_id, media) do
    Enum.each(Map.values(thumbnail_paths(media)), fn path ->
      delete_file_if_present(project_id, path)
    end)

    :ok
  end

  defp media_file_path(file_name, timestamp) do
    datetime = DateTime.from_unix!(timestamp)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["media", year, month, file_name])
  end

  defp detect_mime(file_name) do
    case String.downcase(Path.extname(file_name)) do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".bmp" -> "image/bmp"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> "application/octet-stream"
    end
  end

  defp image_dimensions(source_path, mime_type) do
    if image_mime?(mime_type) do
      case Image.open(source_path) do
        {:ok, image} -> {Image.width(image), Image.height(image)}
        {:error, _reason} -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp image_mime?(mime_type), do: String.starts_with?(mime_type || "", "image/")

  defp binary_exists_for_sidecar?(sidecar_path) do
    sidecar_path
    |> String.trim_trailing(".meta")
    |> File.exists?()
  end

  defp list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join([dir, "**", pattern])
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  defp canonical_sidecar?(sidecar_path) do
    not translation_sidecar?(sidecar_path)
  end

  defp translation_sidecar?(sidecar_path) do
    Regex.match?(~r/\.[a-z]{2}\.meta$/i, sidecar_path)
  end

  defp binary_path_for_translation_sidecar(sidecar_path) do
    Regex.replace(~r/\.[a-z]{2}\.meta$/i, sidecar_path, "")
  end

  defp translation_sidecar_path(media, language), do: "#{media.file_path}.#{language}.meta"

  defp delete_file_if_present(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, contents) do
    temp_path = path <> ".tmp"
    :ok = File.write(temp_path, contents)
    File.rename(temp_path, path)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
