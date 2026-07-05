defmodule BDS.Media.Sidecars do
  @moduledoc false

  import BDS.Media.FileOps,
    only: [
      atomic_write: 2,
      blank_to_nil: 1,
      detect_mime: 1
    ]

  alias BDS.DocumentFields
  alias BDS.Media.Linking
  alias BDS.Media.Media
  alias BDS.Media.Translation
  alias BDS.Persistence
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Sidecar

  @spec write_sidecar(BDS.Projects.Project.t(), Media.t()) :: :ok | {:error, File.posix()}
  def write_sidecar(project, media) do
    path = Path.join(Projects.project_data_dir(project), media.sidecar_path)

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
        {"linkedPostIds", Linking.linked_post_ids(media.id)},
        {"tags", media.tags || []}
      ])
    )
  end

  @spec write_translation_sidecar(BDS.Projects.Project.t(), Media.t(), Translation.t()) ::
          :ok | {:error, File.posix()}
  def write_translation_sidecar(project, media, translation) do
    path =
      Path.join(
        Projects.project_data_dir(project),
        translation_sidecar_path(media, translation.language)
      )

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

  @spec parse_canonical_sidecar(BDS.Projects.Project.t(), Path.t()) ::
          {:ok, map()} | {:error, {:read_sidecar, Path.t(), File.posix()}}
  def parse_canonical_sidecar(project, sidecar_path) do
    with {:ok, contents} <- read_sidecar(sidecar_path),
         {:ok, fields} <- Sidecar.parse_document(contents) do
      relative_sidecar_path = Path.relative_to(sidecar_path, Projects.project_data_dir(project))
      relative_file_path = String.trim_trailing(relative_sidecar_path, ".meta")

      {:ok,
       %{
         fields: fields,
         relative_sidecar_path: relative_sidecar_path,
         relative_file_path: relative_file_path,
         filename: Path.basename(relative_file_path)
       }}
    end
  end

  @spec parse_translation_sidecar(Path.t()) ::
          {:ok, map()} | {:error, {:read_sidecar, Path.t(), File.posix()}}
  def parse_translation_sidecar(sidecar_path) do
    with {:ok, contents} <- read_sidecar(sidecar_path),
         {:ok, fields} <- Sidecar.parse_document(contents) do
      {:ok,
       %{
         fields: fields,
         binary_path: binary_path_for_translation_sidecar(sidecar_path)
       }}
    end
  end

  @spec upsert_media_from_sidecar(BDS.Projects.Project.t(), map(), keyword()) :: Media.t()
  def upsert_media_from_sidecar(project, sidecar, opts) do
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
        Repo.get_by(Media, project_id: project.id, file_path: sidecar.relative_file_path) ||
        %Media{}

    media =
      media
      |> Media.changeset(attrs)
      |> Repo.insert_or_update!()

    Linking.restore_post_links(
      project.id,
      media.id,
      DocumentFields.get(sidecar.fields, "linkedPostIds", [])
    )

    if Keyword.get(opts, :sync_search, true) do
      :ok = Search.sync_media(media)
    end

    media
  end

  @spec upsert_translation_from_sidecar(
          BDS.Projects.Project.t(),
          %{required(Path.t()) => Media.t()},
          map(),
          keyword()
        ) ::
          Translation.t() | :skip | :ok
  def upsert_translation_from_sidecar(project, canonical_media_by_binary_path, sidecar, opts) do
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

  @spec sync_media_sidecar(String.t()) :: :ok | {:error, :not_found | term()}
  def sync_media_sidecar(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)
        write_sidecar(project, media)
    end
  end

  @spec sync_media_from_sidecar(String.t()) :: {:ok, Media.t()} | {:error, :not_found | term()}
  def sync_media_from_sidecar(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      %Media{} = media ->
        project = Projects.get_project!(media.project_id)
        sidecar_path = Path.join(Projects.project_data_dir(project), media.sidecar_path)

        case parse_existing_canonical_sidecar(project, sidecar_path) do
          {:ok, sidecar} ->
            {:ok, upsert_media_from_sidecar(project, sidecar, sync_search: true)}

          {:error, reason} ->
            {:error, reason}
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

        case write_translation_sidecar(project, media, translation) do
          :ok -> {:ok, translation}
          {:error, reason} -> {:error, reason}
        end
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

        sidecar_path =
          Path.join(
            Projects.project_data_dir(project),
            translation_sidecar_path(media, translation.language)
          )

        case parse_existing_translation_sidecar(sidecar_path) do
          {:ok, sidecar} ->
            case BDS.Media.upsert_media_translation(
                   media.id,
                   DocumentFields.fetch!(sidecar.fields, "language"),
                   %{
                     title: DocumentFields.get(sidecar.fields, "title"),
                     alt: DocumentFields.get(sidecar.fields, "alt"),
                     caption: DocumentFields.get(sidecar.fields, "caption")
                   }
                 ) do
              {:ok, updated_translation} -> {:ok, updated_translation}
              error -> error
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec import_orphan_media_sidecar(String.t(), String.t()) ::
          {:ok, Media.t()} | {:error, term()}
  def import_orphan_media_sidecar(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    sidecar_path = Path.join(Projects.project_data_dir(project), relative_path)

    case parse_existing_canonical_sidecar(project, sidecar_path) do
      {:ok, sidecar} ->
        {:ok, upsert_media_from_sidecar(project, sidecar, sync_search: true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec import_orphan_media_translation_sidecar(String.t(), String.t()) ::
          {:ok, Translation.t()} | {:error, term()}
  def import_orphan_media_translation_sidecar(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    sidecar_path = Path.join(Projects.project_data_dir(project), relative_path)

    case parse_existing_translation_sidecar(sidecar_path) do
      {:ok, sidecar} ->
        case Repo.get(Media, DocumentFields.get(sidecar.fields, "translationFor")) do
          nil ->
            {:error, :not_found}

          media ->
            case Repo.get_by(Translation,
                   translation_for: media.id,
                   language: DocumentFields.fetch!(sidecar.fields, "language")
                 ) do
              nil ->
                BDS.Media.upsert_media_translation(
                  media.id,
                  DocumentFields.fetch!(sidecar.fields, "language"),
                  %{
                    title: DocumentFields.get(sidecar.fields, "title"),
                    alt: DocumentFields.get(sidecar.fields, "alt"),
                    caption: DocumentFields.get(sidecar.fields, "caption")
                  }
                )

              _translation ->
                {:error, :conflict}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec translation_sidecar_path(Media.t(), String.t()) :: String.t()
  def translation_sidecar_path(media, language), do: "#{media.file_path}.#{language}.meta"

  @spec canonical_sidecar?(Path.t()) :: boolean()
  def canonical_sidecar?(sidecar_path), do: not translation_sidecar?(sidecar_path)

  @spec translation_sidecar?(Path.t()) :: boolean()
  def translation_sidecar?(sidecar_path) do
    Regex.match?(~r/\.[a-z]{2}\.meta$/i, sidecar_path)
  end

  @spec binary_path_for_translation_sidecar(Path.t()) :: Path.t()
  def binary_path_for_translation_sidecar(sidecar_path) do
    Regex.replace(~r/\.[a-z]{2}\.meta$/i, sidecar_path, "")
  end

  @spec binary_exists_for_sidecar?(Path.t()) :: boolean()
  def binary_exists_for_sidecar?(sidecar_path) do
    sidecar_path
    |> String.trim_trailing(".meta")
    |> File.exists?()
  end

  @doc """
  Read the `linkedPostIds` list persisted in a media item's canonical sidecar.

  The media sidecar is the source of truth for gallery associations (matching
  the old bDS `linkedPostIds` field). Returns `[]` when the sidecar is missing
  or has no linked posts.
  """
  @spec read_linked_post_ids(BDS.Projects.Project.t(), Media.t()) :: [String.t()]
  def read_linked_post_ids(project, %Media{} = media) do
    sidecar_path = Path.join(Projects.project_data_dir(project), media.sidecar_path)

    case parse_existing_canonical_sidecar(project, sidecar_path) do
      {:ok, sidecar} ->
        sidecar.fields
        |> DocumentFields.get("linkedPostIds", [])
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      {:error, _reason} ->
        []
    end
  end

  defp parse_existing_canonical_sidecar(project, sidecar_path) do
    if File.exists?(sidecar_path) do
      parse_canonical_sidecar(project, sidecar_path)
    else
      {:error, :not_found}
    end
  end

  defp parse_existing_translation_sidecar(sidecar_path) do
    if File.exists?(sidecar_path) do
      parse_translation_sidecar(sidecar_path)
    else
      {:error, :not_found}
    end
  end

  defp read_sidecar(sidecar_path) do
    case File.read(sidecar_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_sidecar, sidecar_path, reason}}
    end
  end
end
