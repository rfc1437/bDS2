defmodule BDS.Media do
  @moduledoc """
  Context for media assets and their translations: import, update, replace, and
  delete media, and manage per-language metadata translations.

  Each operation keeps the database record, the media file on disk, and the
  derived metadata in sync.
  """

  import BDS.Media.FileOps,
    only: [
      attr: 2,
      delete_file_if_present: 2,
      detect_mime: 1,
      image_dimensions: 2,
      maybe_put: 3,
      media_file_path: 2
    ]

  import BDS.Media.Sidecars,
    only: [
      translation_sidecar_path: 2,
      write_sidecar: 2,
      write_translation_sidecar: 3
    ]

  import BDS.Media.Thumbnails,
    only: [
      delete_thumbnail_files: 2,
      ensure_thumbnails: 2
    ]

  require Logger

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Media.Translation
  alias BDS.Persistence
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search

  @typedoc "An attribute map that may use atom or string keys."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @typedoc "Options accepted by long-running rebuild operations."
  @type rebuild_opts :: keyword()

  # Public API delegations to submodules
  defdelegate thumbnail_paths(media), to: BDS.Media.Thumbnails
  defdelegate regenerate_thumbnails(media_id), to: BDS.Media.Thumbnails
  defdelegate regenerate_missing_thumbnails(project_id), to: BDS.Media.Thumbnails
  defdelegate regenerate_missing_thumbnails(project_id, opts), to: BDS.Media.Thumbnails

  defdelegate sync_media_sidecar(media_id), to: BDS.Media.Sidecars
  defdelegate sync_media_from_sidecar(media_id), to: BDS.Media.Sidecars
  defdelegate sync_media_translation_sidecar(translation_id), to: BDS.Media.Sidecars
  defdelegate sync_media_translation_from_sidecar(translation_id), to: BDS.Media.Sidecars
  defdelegate import_orphan_media_sidecar(project_id, relative_path), to: BDS.Media.Sidecars

  defdelegate import_orphan_media_translation_sidecar(project_id, relative_path),
    to: BDS.Media.Sidecars

  defdelegate list_linked_posts(media_id), to: BDS.Media.Linking
  defdelegate link_media_to_post(media_id, post_id), to: BDS.Media.Linking
  defdelegate unlink_media_from_post(media_id, post_id), to: BDS.Media.Linking

  defdelegate rebuild_media_from_files(project_id), to: BDS.Media.Rebuilder
  defdelegate rebuild_media_from_files(project_id, opts), to: BDS.Media.Rebuilder

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
        log_sidecar_error(write_sidecar(project, media), media.id)
        log_thumbnail_error(ensure_thumbnails(project, media), media.id)
        :ok = Search.sync_media(media)
        {:ok, media}

      {:error, reason} ->
        _ = File.rm(destination)
        {:error, reason}
    end
  end

  @spec get_media(String.t()) :: Media.t() | nil
  def get_media(media_id), do: Repo.get(Media, media_id)

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
            log_sidecar_error(write_sidecar(project, updated_media), updated_media.id)
            :ok = Search.sync_media(updated_media)
            {:ok, updated_media}

          {:error, reason} ->
            {:error, reason}
        end
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

        transaction_result =
          Repo.transaction(fn ->
            Enum.each(translations, fn translation ->
              case Repo.delete(translation) do
                {:ok, _} -> :ok
                {:error, changeset} -> Repo.rollback(changeset)
              end
            end)

            case Repo.delete(media) do
              {:ok, deleted} -> deleted
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case transaction_result do
          {:ok, _deleted_media} ->
            delete_file_if_present(media.project_id, media.file_path)
            delete_file_if_present(media.project_id, media.sidecar_path)
            delete_thumbnail_files(media.project_id, media)

            Enum.each(translations, fn translation ->
              delete_file_if_present(
                media.project_id,
                translation_sidecar_path(media, translation.language)
              )
            end)

            Search.delete_media(media.id)
            {:ok, :deleted}

          {:error, reason} ->
            {:error, reason}
        end
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
            log_sidecar_error(
              write_translation_sidecar(project, media, updated_translation),
              media.id
            )

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

            case Repo.delete(translation) do
              {:ok, _deleted} ->
                delete_file_if_present(
                  media.project_id,
                  translation_sidecar_path(media, normalized_language)
                )

                :ok = Search.sync_media(media)
                log_sidecar_error(write_sidecar(project, media), media.id)
                {:ok, true}

              {:error, changeset} ->
                {:error, changeset}
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
                log_sidecar_error(write_sidecar(project, updated_media), updated_media.id)
                log_thumbnail_error(ensure_thumbnails(project, updated_media), updated_media.id)
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

  @spec validate_media(String.t()) :: [%{media_id: String.t(), issue: String.t()}]
  def validate_media(project_id) do
    project = BDS.Projects.get_project!(project_id)
    data_dir = BDS.Projects.project_data_dir(project)

    Repo.all(from m in Media, where: m.project_id == ^project_id)
    |> Enum.flat_map(fn media ->
      issues = []

      binary_path = Path.join(data_dir, media.file_path)
      issues = if File.exists?(binary_path), do: issues, else: [%{media_id: media.id, issue: "missing_binary"} | issues]

      sidecar_path = Path.join(data_dir, media.sidecar_path)
      issues = if File.exists?(sidecar_path), do: issues, else: [%{media_id: media.id, issue: "missing_sidecar"} | issues]

      issues =
        if BDS.Media.FileOps.image_mime?(media.mime_type) do
          thumbnails = BDS.Media.Thumbnails.thumbnail_paths(media)

          Enum.reduce([:small, :medium, :large, :ai], issues, fn size, acc ->
            thumb_path = Path.join(data_dir, Map.fetch!(thumbnails, size))

            if File.exists?(thumb_path),
              do: acc,
              else: [%{media_id: media.id, issue: "missing_thumbnail_#{size}"} | acc]
          end)
        else
          issues
        end

      issues =
        if BDS.Media.FileOps.image_mime?(media.mime_type) and File.exists?(binary_path) do
          case BDS.Media.FileOps.image_dimensions(binary_path, media.mime_type) do
            {nil, nil} -> [%{media_id: media.id, issue: "corrupted"} | issues]
            _ -> issues
          end
        else
          issues
        end

      linked_posts = BDS.Media.Linking.list_linked_posts(media.id)
      issues = if linked_posts == [], do: [%{media_id: media.id, issue: "orphan"} | issues], else: issues

      Enum.reverse(issues)
    end)
  end

  defp log_thumbnail_error(:ok, _media_id), do: :ok

  defp log_thumbnail_error({:error, reason}, media_id) do
    Logger.warning("Thumbnail generation failed for media #{media_id}: #{inspect(reason)}")
  end

  defp log_sidecar_error(:ok, _media_id), do: :ok

  defp log_sidecar_error({:error, reason}, media_id) do
    Logger.warning("Sidecar write failed for media #{media_id}: #{inspect(reason)}")
  end
end
