defmodule BDS.Media do
  @moduledoc false

  import Ecto.Query

  alias BDS.DocumentFields
  alias BDS.Media.Media
  alias BDS.Media.Translation
  alias BDS.Persistence
  alias BDS.Posts.PostMedia
  alias BDS.Projects
  alias BDS.Rebuild
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Sidecar

  @typedoc "An attribute map that may use atom or string keys."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @typedoc "Options accepted by long-running rebuild operations."
  @type rebuild_opts :: keyword()

  @spec import_media(attrs()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t() | term()}
  def import_media(attrs) do
    project = Projects.get_project!(attr(attrs, :project_id))
    source_path = attr(attrs, :source_path)
    original_name = Path.basename(source_path)
    mime_type = detect_mime(original_name)
    {width, height} = image_dimensions(source_path, mime_type)
    now = Persistence.now_ms()
    file_name = Ecto.UUID.generate() <> Path.extname(original_name)
    file_path = media_file_path(file_name, now)
    sidecar_path = file_path <> ".meta"
    destination = Path.join(Projects.project_data_dir(project), file_path)
    stat = File.stat!(source_path)

    :ok = File.mkdir_p(Path.dirname(destination))
    :ok = File.cp(source_path, destination)

    case Repo.transaction(fn ->
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
         end) do
      {:ok, media} ->
        :ok = write_sidecar(project, media)
        :ok = ensure_thumbnails(project, media)
        :ok = Search.sync_media(media)
        {:ok, media}

      {:error, reason} ->
        _ = File.rm(destination)
        {:error, reason}
    end
  end

  @spec update_media(String.t(), attrs()) ::
          {:ok, Media.t()} | {:error, :not_found | Ecto.Changeset.t()}
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
          |> Map.put(:updated_at, Persistence.now_ms())

        project = Projects.get_project!(media.project_id)

        case Repo.transaction(fn ->
               media
               |> Media.changeset(updates)
               |> Repo.update!()
             end) do
          {:ok, updated_media} ->
            :ok = write_sidecar(project, updated_media)
            :ok = Search.sync_media(updated_media)
            {:ok, updated_media}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec sync_media_sidecar(String.t()) :: :ok | {:error, :not_found | term()}
  def sync_media_sidecar(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        :ok = write_sidecar(project, media)
        :ok
    end
  end

  @spec sync_media_from_sidecar(String.t()) ::
          {:ok, Media.t()} | {:error, :not_found | term()}
  def sync_media_from_sidecar(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      %Media{} = media ->
        project = Projects.get_project!(media.project_id)
        sidecar_path = Path.join(Projects.project_data_dir(project), media.sidecar_path)

        if File.exists?(sidecar_path) do
          {:ok, upsert_media_from_sidecar(project, parse_canonical_sidecar(project, sidecar_path), sync_search: true)}
        else
          {:error, :not_found}
        end
    end
  end

  @spec sync_media_translation_sidecar(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found | term()}
  def sync_media_translation_sidecar(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{} = translation ->
        media = Repo.get!(Media, translation.translation_for)
        project = Projects.get_project!(media.project_id)
        :ok = write_translation_sidecar(project, media, translation)
        {:ok, translation}
    end
  end

  @spec sync_media_translation_from_sidecar(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found | term()}
  def sync_media_translation_from_sidecar(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{} = translation ->
        media = Repo.get!(Media, translation.translation_for)
        project = Projects.get_project!(media.project_id)
        sidecar_path = Path.join(Projects.project_data_dir(project), translation_sidecar_path(media, translation.language))

        if File.exists?(sidecar_path) do
          sidecar = parse_translation_sidecar(sidecar_path)

          case upsert_media_translation(media.id, DocumentFields.fetch!(sidecar.fields, "language"), %{
                 title: DocumentFields.get(sidecar.fields, "title"),
                 alt: DocumentFields.get(sidecar.fields, "alt"),
                 caption: DocumentFields.get(sidecar.fields, "caption")
               }) do
            {:ok, updated_translation} -> {:ok, updated_translation}
            error -> error
          end
        else
          {:error, :not_found}
        end
    end
  end

  @spec import_orphan_media_sidecar(String.t(), String.t()) ::
          {:ok, Media.t()} | {:error, term()}
  def import_orphan_media_sidecar(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    sidecar_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(sidecar_path) do
      {:ok, upsert_media_from_sidecar(project, parse_canonical_sidecar(project, sidecar_path), sync_search: true)}
    else
      {:error, :not_found}
    end
  end

  @spec import_orphan_media_translation_sidecar(String.t(), String.t()) ::
          {:ok, Translation.t()} | {:error, term()}
  def import_orphan_media_translation_sidecar(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    sidecar_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(sidecar_path) do
      sidecar = parse_translation_sidecar(sidecar_path)

      case Repo.get(Media, DocumentFields.get(sidecar.fields, "translationFor")) do
        nil ->
          {:error, :not_found}

        media ->
          case Repo.get_by(Translation,
                 translation_for: media.id,
                 language: DocumentFields.fetch!(sidecar.fields, "language")
               ) do
            nil ->
              upsert_media_translation(media.id, DocumentFields.fetch!(sidecar.fields, "language"), %{
                title: DocumentFields.get(sidecar.fields, "title"),
                alt: DocumentFields.get(sidecar.fields, "alt"),
                caption: DocumentFields.get(sidecar.fields, "caption")
              })

            _translation ->
              {:error, :conflict}
          end
      end
    else
      {:error, :not_found}
    end
  end

  @spec delete_media(String.t()) :: {:ok, :deleted} | {:error, :not_found}
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

  @spec upsert_media_translation(String.t(), String.t() | atom(), attrs()) ::
          {:ok, Translation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def upsert_media_translation(media_id, language, attrs) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        now = Persistence.now_ms()

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

        case Repo.transaction(fn ->
               translation
               |> Translation.changeset(translation_attrs)
               |> Repo.insert_or_update!()
             end) do
          {:ok, updated_translation} ->
            :ok = write_translation_sidecar(project, media, updated_translation)
            :ok = Search.sync_media(media.id)
            {:ok, updated_translation}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec delete_media_translation(String.t(), String.t() | atom()) ::
          {:ok, boolean()} | {:error, :not_found | term()}
  def delete_media_translation(media_id, language) do
    normalized_language = language |> to_string() |> String.trim() |> String.downcase()

    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        case Repo.get_by(Translation, translation_for: media.id, language: normalized_language) do
          nil ->
            {:ok, false}

          translation ->
            project = Projects.get_project!(media.project_id)

            case Repo.transaction(fn -> Repo.delete!(translation) end) do
              {:ok, _deleted} ->
                delete_file_if_present(media.project_id, translation_sidecar_path(media, normalized_language))
                :ok = Search.sync_media(media)
                :ok = write_sidecar(project, media)
                {:ok, true}

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  @spec replace_media_file(String.t(), String.t()) ::
          {:ok, Media.t() | nil} | {:error, :not_found | Ecto.Changeset.t() | term()}
  def replace_media_file(media_id, new_source_path) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        destination = Path.join(Projects.project_data_dir(project), media.file_path)

        with {:ok, binary} <- File.read(new_source_path),
             {:ok, stat} <- File.stat(new_source_path) do
          checksum = Base.encode16(:crypto.hash(:md5, binary), case: :lower)

          if checksum == media.checksum do
            {:ok, nil}
          else
            mime_type = media.mime_type || detect_mime(media.original_name || media.filename)
            {width, height} = image_dimensions(new_source_path, mime_type)
            previous_destination_backup = destination <> ".bak"
            _ = File.rename(destination, previous_destination_backup)
            :ok = File.cp(new_source_path, destination)

            case Repo.transaction(fn ->
                   media
                   |> Media.changeset(%{
                     size: stat.size,
                     width: width || media.width,
                     height: height || media.height,
                     checksum: checksum,
                     updated_at: Persistence.now_ms()
                   })
                   |> Repo.update!()
                 end) do
              {:ok, updated_media} ->
                _ = File.rm(previous_destination_backup)
                :ok = write_sidecar(project, updated_media)
                :ok = ensure_thumbnails(project, updated_media)
                :ok = Search.sync_media(updated_media)
                {:ok, updated_media}

              {:error, reason} ->
                _ = File.rename(previous_destination_backup, destination)
                {:error, reason}
            end
          end
        end
    end
  end

  @spec list_media_translations(String.t()) :: [Translation.t()]
  def list_media_translations(media_id) when is_binary(media_id) do
    Repo.all(
      from translation in Translation,
        where: translation.translation_for == ^media_id,
        order_by: [asc: translation.language]
    )
  end

  @spec list_linked_posts(String.t()) :: [%{post_id: String.t(), title: String.t(), sort_order: integer()}]
  def list_linked_posts(media_id) when is_binary(media_id) do
    Repo.all(
      from post in BDS.Posts.Post,
        join: pm in PostMedia,
        on: pm.post_id == post.id,
        where: pm.media_id == ^media_id,
        order_by: [asc: pm.sort_order, asc: post.updated_at],
        select: %{
          post_id: post.id,
          title: fragment("COALESCE(?, ?, ?)", post.title, post.slug, post.id),
          sort_order: pm.sort_order
        }
    )
  end

  @spec link_media_to_post(String.t(), String.t()) ::
          {:ok, :linked} | {:error, :not_found | term()}
  def link_media_to_post(media_id, post_id) when is_binary(media_id) and is_binary(post_id) do
    case {Repo.get(Media, media_id), Repo.get(BDS.Posts.Post, post_id)} do
      {nil, _post} ->
        {:error, :not_found}

      {_media, nil} ->
        {:error, :not_found}

      {%Media{} = media, %BDS.Posts.Post{} = post} ->
        project = Projects.get_project!(media.project_id)

        case Repo.transaction(fn ->
               if Repo.exists?(from pm in PostMedia, where: pm.post_id == ^post.id and pm.media_id == ^media.id) do
                 :already_linked
               else
                 sort_order = next_sort_order(media.id)

                 %PostMedia{}
                 |> PostMedia.changeset(%{
                   id: Ecto.UUID.generate(),
                   project_id: media.project_id,
                   post_id: post.id,
                   media_id: media.id,
                   sort_order: sort_order,
                   created_at: Persistence.now_ms()
                 })
                 |> Repo.insert!()

                 :linked
               end
             end) do
          {:ok, _result} ->
            :ok = write_sidecar(project, media)
            {:ok, :linked}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec unlink_media_from_post(String.t(), String.t()) ::
          {:ok, :unlinked} | {:error, :not_found | term()}
  def unlink_media_from_post(media_id, post_id) when is_binary(media_id) and is_binary(post_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      %Media{} = media ->
        project = Projects.get_project!(media.project_id)

        case Repo.transaction(fn ->
               {_count, _} =
                 Repo.delete_all(
                   from pm in PostMedia, where: pm.media_id == ^media.id and pm.post_id == ^post_id
                 )

               :ok
             end) do
          {:ok, :ok} ->
            :ok = write_sidecar(project, media)
            {:ok, :unlinked}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec thumbnail_paths(Media.t()) :: %{required(atom()) => String.t()}
  def thumbnail_paths(%Media{id: id}) do
    prefix = String.slice(id, 0, 2)

    %{
      small: Path.join(["thumbnails", prefix, "#{id}-small.webp"]),
      medium: Path.join(["thumbnails", prefix, "#{id}-medium.webp"]),
      large: Path.join(["thumbnails", prefix, "#{id}-large.webp"]),
      ai: Path.join(["thumbnails", prefix, "#{id}-ai.jpg"])
    }
  end

  @spec regenerate_thumbnails(String.t()) :: {:ok, Media.t()} | {:error, :not_found | term()}
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

  @spec regenerate_missing_thumbnails(String.t(), rebuild_opts()) ::
          %{processed: non_neg_integer(), generated: non_neg_integer(), failed: non_neg_integer()}
  def regenerate_missing_thumbnails(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    media_items =
      Repo.all(
      from(media in Media,
        where: media.project_id == ^project_id,
        order_by: [asc: media.created_at]
      )
      )
      |> Enum.filter(fn media ->
        String.starts_with?(media.mime_type || "", "image/") and
          not String.contains?(media.mime_type || "", "svg")
      end)

    total_media = length(media_items)
    :ok = report_rebuild_started(on_progress, total_media, "image assets")

    media_items
    |> Enum.with_index(1)
    |> Enum.reduce(%{processed: 0, generated: 0, failed: 0}, fn {media, index}, acc ->
      missing_paths =
        media
        |> thumbnail_paths()
        |> Enum.map(fn {_size, relative_path} -> Path.join(Projects.project_data_dir(project), relative_path) end)
        |> Enum.reject(&File.exists?/1)

      next_acc =
        if missing_paths == [] do
          %{acc | processed: acc.processed + 1}
        else
          try do
            :ok = ensure_thumbnails(project, media)

            %{
              processed: acc.processed + 1,
              generated: acc.generated + length(missing_paths),
              failed: acc.failed
            }
          rescue
            _error ->
              %{acc | processed: acc.processed + 1, failed: acc.failed + 1}
          end
        end

      :ok = report_rebuild_progress(on_progress, index, total_media, "image assets")
      next_acc
    end)
  end

  @spec rebuild_media_from_files(String.t(), rebuild_opts()) :: {:ok, [Media.t()]}
  def rebuild_media_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    canonical_sidecars =
      project
      |> Projects.project_data_dir()
      |> Path.join("media")
      |> list_matching_files("*.meta")
      |> Enum.filter(&canonical_sidecar?/1)
      |> Enum.filter(&binary_exists_for_sidecar?/1)
      |> Rebuild.parallel_map(&parse_canonical_sidecar(project, &1))

    translation_sidecars =
      project
      |> Projects.project_data_dir()
      |> Path.join("media")
      |> list_matching_files("*.meta")
      |> Enum.filter(&translation_sidecar?/1)
      |> Rebuild.parallel_map(&parse_translation_sidecar(&1))

    total_files = length(canonical_sidecars) + length(translation_sidecars)
    :ok = report_rebuild_started(on_progress, total_files, "media files")

    media_items =
      canonical_sidecars
      |> Enum.with_index(1)
      |> Enum.map(fn {sidecar, index} ->
        media = upsert_media_from_sidecar(project, sidecar, sync_search: false)
        :ok = report_rebuild_progress(on_progress, index, total_files, "media files")
        media
      end)

    canonical_media_by_binary_path =
      Map.new(media_items, fn media ->
        {Path.join(Projects.project_data_dir(project), media.file_path), media}
      end)

    translation_sidecars
    |> Enum.with_index(length(canonical_sidecars) + 1)
    |> Enum.each(fn {sidecar, index} ->
      upsert_translation_from_sidecar(project, canonical_media_by_binary_path, sidecar, sync_search: false)
      :ok = report_rebuild_progress(on_progress, index, total_files, "media files")
    end)

    if Keyword.get(opts, :reindex_search, true) do
      :ok = report_rebuild_phase(on_progress, 0.99, "Refreshing media search index")
      :ok =
        Search.reindex_media(project.id,
          on_progress: scaled_progress_reporter(on_progress, 0.99, 1.0)
        )
    end

    {:ok, media_items}
  end

  defp upsert_media_from_sidecar(project, sidecar, opts) do
    now = Persistence.now_ms()

    attrs = %{
      id: DocumentFields.get(sidecar.fields, "id") || Ecto.UUID.generate(),
      project_id: project.id,
      filename: sidecar.filename,
      original_name: DocumentFields.get(sidecar.fields, "originalName") || sidecar.filename,
      mime_type: DocumentFields.get(sidecar.fields, "mimeType") || detect_mime(sidecar.filename),
      size: DocumentFields.get(sidecar.fields, "size", 0),
      width: blank_to_nil(DocumentFields.get(sidecar.fields, "width")),
      height: blank_to_nil(DocumentFields.get(sidecar.fields, "height")),
      title: DocumentFields.get(sidecar.fields, "title"),
      alt: DocumentFields.get(sidecar.fields, "alt"),
      caption: DocumentFields.get(sidecar.fields, "caption"),
      author: DocumentFields.get(sidecar.fields, "author"),
      language: DocumentFields.get(sidecar.fields, "language"),
      file_path: sidecar.relative_file_path,
      sidecar_path: sidecar.relative_sidecar_path,
      checksum: nil,
      tags: DocumentFields.get(sidecar.fields, "tags", []),
      created_at: DocumentFields.get(sidecar.fields, "createdAt", now),
      updated_at: DocumentFields.get(sidecar.fields, "updatedAt", now)
    }

    media =
      Repo.get(Media, attrs.id) ||
        Repo.get_by(Media, project_id: project.id, file_path: sidecar.relative_file_path) || %Media{}

    media =
      media
      |> Media.changeset(attrs)
      |> Repo.insert_or_update!()

    if Keyword.get(opts, :sync_search, true) do
      :ok = Search.sync_media(media)
    end

    media
  end

  defp write_sidecar(project, media) do
    path = Path.join(Projects.project_data_dir(project), media.sidecar_path)
    :ok = File.mkdir_p(Path.dirname(path))

    atomic_write(
      path,
      Sidecar.serialize_document([
        {"id", media.id},
        {"originalName", media.original_name},
        {"mimeType", media.mime_type},
        {"size", media.size},
        {"width", media.width},
        {"height", media.height},
        {"title", media.title},
        {"alt", media.alt},
        {"caption", media.caption},
        {"author", media.author},
        {"language", media.language},
        {"createdAt", media.created_at},
        {"updatedAt", media.updated_at},
        {"linkedPostIds", linked_post_ids(media.id)},
        {"tags", media.tags || []}
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
        {"translationFor", media.id},
        {"language", translation.language},
        {"title", translation.title},
        {"alt", translation.alt},
        {"caption", translation.caption}
      ])
    )
  end

  defp upsert_translation_from_sidecar(project, canonical_media_by_binary_path, sidecar, opts) do
    case Map.get(canonical_media_by_binary_path, sidecar.binary_path) do
      nil ->
        :skip

      media ->
        now = Persistence.now_ms()
        language = DocumentFields.fetch!(sidecar.fields, "language")

        translation =
          Repo.get_by(Translation, translation_for: media.id, language: language) ||
            %Translation{id: Ecto.UUID.generate(), created_at: now}

        translation
        |> Translation.changeset(%{
          id: translation.id,
          project_id: project.id,
          translation_for: media.id,
          language: language,
          title: DocumentFields.get(sidecar.fields, "title"),
          alt: DocumentFields.get(sidecar.fields, "alt"),
          caption: DocumentFields.get(sidecar.fields, "caption"),
          created_at: translation.created_at || now,
          updated_at: now
        })
        |> Repo.insert_or_update!()

        if Keyword.get(opts, :sync_search, true) do
          :ok = Search.sync_media(media.id)
        end
    end
  end

  defp parse_canonical_sidecar(project, sidecar_path) do
    {:ok, fields} = sidecar_path |> File.read!() |> Sidecar.parse_document()
    relative_sidecar_path = Path.relative_to(sidecar_path, Projects.project_data_dir(project))
    relative_file_path = String.trim_trailing(relative_sidecar_path, ".meta")

    %{
      fields: fields,
      relative_sidecar_path: relative_sidecar_path,
      relative_file_path: relative_file_path,
      filename: Path.basename(relative_file_path)
    }
  end

  defp parse_translation_sidecar(sidecar_path) do
    {:ok, fields} = sidecar_path |> File.read!() |> Sidecar.parse_document()

    %{
      fields: fields,
      binary_path: binary_path_for_translation_sidecar(sidecar_path)
    }
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
    datetime = Persistence.from_unix_ms!(timestamp)
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
    Persistence.atomic_write(path, contents)
  end

  defp linked_post_ids(media_id) do
    Repo.all(
      from pm in PostMedia,
        where: pm.media_id == ^media_id,
        order_by: [asc: pm.sort_order, asc: pm.post_id],
        select: pm.post_id
    )
  end

  defp next_sort_order(media_id) do
    case Repo.one(
           from pm in PostMedia,
             where: pm.media_id == ^media_id,
             select: max(pm.sort_order)
         ) do
      value when is_integer(value) -> value + 1
      _other -> 0
    end
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

  defp progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  defp scaled_progress_reporter(nil, _start_value, _end_value), do: nil

  defp scaled_progress_reporter(report, start_value, end_value) when is_function(report, 2) do
    fn value, message ->
      scaled_value = start_value + (end_value - start_value) * value
      report.(scaled_value, message)
    end
  end

  defp report_rebuild_started(nil, _total, _label), do: :ok

  defp report_rebuild_started(callback, 0, label) do
    callback.(1.0, "No #{label} found")
    :ok
  end

  defp report_rebuild_started(callback, total, label) do
    callback.(0.05, "Rebuilding #{label} (0/#{total})")
    :ok
  end

  defp report_rebuild_progress(nil, _current, _total, _label), do: :ok
  defp report_rebuild_progress(_callback, _current, 0, _label), do: :ok

  defp report_rebuild_progress(callback, current, total, label) do
    callback.(0.05 + 0.95 * (current / total), "Rebuilding #{label} (#{current}/#{total})")
    :ok
  end

  defp report_rebuild_phase(nil, _progress, _message), do: :ok

  defp report_rebuild_phase(callback, progress, message) do
    callback.(progress, message)
    :ok
  end
end
