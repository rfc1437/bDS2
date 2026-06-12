defmodule BDS.Posts.RebuildFromFiles do
  @moduledoc false

  alias BDS.DocumentFields
  alias BDS.Embeddings
  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.ProgressReporter
  alias BDS.Posts.Post
  alias BDS.Posts.Slugs
  alias BDS.Posts.Translation
  alias BDS.Posts.TranslationValidation
  alias BDS.Projects
  alias BDS.Rebuild
  alias BDS.Repo
  alias BDS.Search

  @transaction_batch_size 500

  @spec rebuild_posts_from_files(String.t(), keyword()) :: {:ok, [Post.t()]} | {:error, term()}
  def rebuild_posts_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    rebuild_results =
      project
      |> Projects.project_data_dir()
      |> Path.join("posts")
      |> TranslationValidation.list_matching_files("*.md")
      |> Rebuild.parallel_map(&parse_rebuild_file(project, &1))

    with {:ok, rebuild_files} <- collect_rebuild_files(rebuild_results) do
      total_files = length(rebuild_files)
      :ok = report_rebuild_started(on_progress, total_files, "post files")

      {translation_files, post_files} =
        Enum.split_with(rebuild_files, &TranslationValidation.translation_rebuild_file?/1)

      operations = Enum.map(post_files, &{:post, &1}) ++ Enum.map(translation_files, &{:translation, &1})

      with {:ok, posts} <- persist_rebuild_operations(project_id, operations, total_files, on_progress) do
        if Keyword.get(opts, :reindex_search, true) do
          :ok = report_rebuild_phase(on_progress, 0.97, "Refreshing post search index")

          :ok =
            Search.reindex_posts(project_id,
              on_progress: scaled_progress_reporter(on_progress, 0.97, 0.99)
            )
        end

        if Keyword.get(opts, :rebuild_embeddings, true) do
          :ok = report_rebuild_phase(on_progress, 0.99, "Refreshing post embeddings")

          {:ok, _rebuilt_post_ids} =
            Embeddings.rebuild_project(project_id,
              on_progress: scaled_progress_reporter(on_progress, 0.99, 1.0)
            )
        end

        {:ok, posts}
      end
    end
  end

  @spec import_orphan_post_file(String.t(), String.t()) ::
          {:ok, Post.t()} | {:error, :not_found | :unsupported_file}
  def import_orphan_post_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(full_path) do
      with {:ok, rebuild_file} <- parse_rebuild_file(project, full_path) do
        if TranslationValidation.translation_rebuild_file?(rebuild_file) do
          {:error, :unsupported_file}
        else
          fields =
            rebuild_file.fields
            |> Map.put("id", unique_post_id(Map.get(rebuild_file.fields, "id")))
            |> Map.put(
              "slug",
              Slugs.unique_for_import(project_id, Map.fetch!(rebuild_file.fields, "slug"))
            )

          {:ok,
           upsert_post_from_rebuild_file(project_id, %{rebuild_file | fields: fields},
             sync_embeddings: false
           )}
        end
      end
    else
      {:error, :not_found}
    end
  end

  @spec import_orphan_post_translation_file(String.t(), String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found | :unsupported_file | :conflict}
  def import_orphan_post_translation_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(full_path) do
      with {:ok, rebuild_file} <- parse_rebuild_file(project, full_path) do
        if TranslationValidation.translation_rebuild_file?(rebuild_file) do
          source_post_id = Map.fetch!(rebuild_file.fields, "translationFor")

          language =
            TranslationValidation.normalize_language(Map.fetch!(rebuild_file.fields, "language"))

          case Repo.get(Post, source_post_id) do
            nil ->
              {:error, :not_found}

            %Post{} = post ->
              if TranslationValidation.normalize_language(post.language) == language or
                   Repo.get_by(Translation, translation_for: source_post_id, language: language) do
                {:error, :conflict}
              else
                fields = Map.put(rebuild_file.fields, "id", Ecto.UUID.generate())

                {:ok,
                 upsert_post_translation_from_rebuild_file(
                   project_id,
                   %{rebuild_file | fields: fields},
                   sync_search: true
                 )}
              end
          end
        else
          {:error, :unsupported_file}
        end
      end
    else
      {:error, :not_found}
    end
  end

  @doc false
  def upsert_post_from_file(project_id, project, path) do
    with {:ok, rebuild_file} <- parse_rebuild_file(project, path) do
      {:ok, upsert_post_from_rebuild_file(project_id, rebuild_file)}
    end
  end

  @doc false
  def upsert_post_from_rebuild_file(project_id, rebuild_file, opts \\ []) do
    fields = rebuild_file.fields
    now = Persistence.now_ms()

    attrs = %{
      id: DocumentFields.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      title: DocumentFields.get(fields, "title") || "",
      slug: DocumentFields.fetch!(fields, "slug"),
      excerpt: Map.get(fields, "excerpt"),
      content: nil,
      status: parse_post_status(DocumentFields.get(fields, "status", "published")),
      author: Map.get(fields, "author"),
      created_at: DocumentFields.get(fields, "createdAt", now),
      updated_at: DocumentFields.get(fields, "updatedAt", now),
      published_at: DocumentFields.get(fields, "publishedAt"),
      file_path: rebuild_file.relative_path,
      checksum: nil,
      tags: Map.get(fields, "tags", []),
      categories: Map.get(fields, "categories", []),
      template_slug: DocumentFields.get(fields, "templateSlug"),
      language: Map.get(fields, "language"),
      do_not_translate: DocumentFields.get(fields, "doNotTranslate", false),
      published_title: nil,
      published_content: nil,
      published_tags: nil,
      published_categories: nil,
      published_excerpt: nil
    }

    post =
      Repo.get(Post, attrs.id) ||
        Repo.get_by(Post, project_id: project_id, file_path: rebuild_file.relative_path) ||
        Repo.get_by(Post, project_id: project_id, slug: attrs.slug) || %Post{}

    post =
      post
      |> Post.changeset(attrs)
      |> Repo.insert_or_update!()

    if Keyword.get(opts, :sync_search, true) do
      :ok = Search.sync_post(post)
    end

    if Keyword.get(opts, :sync_embeddings, true) do
      :ok = Embeddings.sync_post(post)
    end

    post
  end

  @doc false
  def upsert_post_translation_from_rebuild_file(project_id, rebuild_file, opts) do
    fields = rebuild_file.fields
    source_post_id = DocumentFields.fetch!(fields, "translationFor")
    source_post = Repo.get_by!(Post, project_id: project_id, id: source_post_id)
    now = Persistence.now_ms()
    language = TranslationValidation.normalize_language(DocumentFields.fetch!(fields, "language"))

    translation =
      Repo.get_by(Translation, translation_for: source_post_id, language: language) ||
        %Translation{}

    attrs = %{
      id: DocumentFields.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      translation_for: source_post_id,
      language: language,
      title: DocumentFields.get(fields, "title") || "",
      excerpt: Map.get(fields, "excerpt"),
      content: nil,
      status: parse_translation_status(DocumentFields.get(fields, "status", "published")),
      created_at: DocumentFields.get(fields, "createdAt", source_post.created_at || now),
      updated_at:
        DocumentFields.get(
          fields,
          "updatedAt",
          source_post.updated_at || source_post.created_at || now
        ),
      published_at: DocumentFields.get(fields, "publishedAt", source_post.published_at),
      file_path: rebuild_file.relative_path,
      checksum: nil
    }

    translation
    |> Translation.changeset(attrs)
    |> Repo.insert_or_update!()
    |> tap(fn _translation ->
      if Keyword.get(opts, :sync_search, true) do
        :ok = Search.sync_post(source_post_id)
      end
    end)
  end

  @doc false
  def parse_rebuild_file(project, path) do
    with {:ok, contents} <- read_rebuild_file(path),
         {:ok, %{fields: fields}} <- Frontmatter.parse_document(contents) do
      {:ok,
       %{
         path: path,
         relative_path: Path.relative_to(path, Projects.project_data_dir(project)),
         fields: fields
       }}
    end
  end

  @doc false
  def parse_post_status(status), do: BDS.BoundedAtoms.post_status(status, :draft)

  @doc false
  def parse_translation_status(status), do: BDS.BoundedAtoms.translation_status(status, :draft)

  @doc false
  def progress_callback(opts), do: ProgressReporter.callback(opts)

  @doc false
  def report_rebuild_started(callback, total, label),
    do: ProgressReporter.report_rebuild_started(callback, total, label)

  @doc false
  def report_rebuild_progress(callback, current, total, label),
    do: ProgressReporter.report_rebuild_progress(callback, current, total, label)

  defp scaled_progress_reporter(report, start_value, end_value),
    do: ProgressReporter.scaled(report, start_value, end_value)

  defp report_rebuild_phase(callback, progress, message),
    do: ProgressReporter.report_phase(callback, progress, message)

  defp unique_post_id(nil), do: Ecto.UUID.generate()

  defp unique_post_id(id) do
    if Repo.get(Post, id) || Repo.get(Translation, id) do
      Ecto.UUID.generate()
    else
      id
    end
  end

  defp collect_rebuild_files(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, rebuild_file}, {:ok, rebuild_files} -> {:cont, {:ok, [rebuild_file | rebuild_files]}}
      {:error, reason}, {:ok, _rebuild_files} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, rebuild_files} -> {:ok, Enum.reverse(rebuild_files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_rebuild_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_rebuild_file, path, reason}}
    end
  end

  defp persist_rebuild_operations(project_id, operations, total_files, on_progress) do
    operations
    |> Enum.chunk_every(@transaction_batch_size)
    |> Enum.reduce_while({:ok, [], 0}, fn chunk, {:ok, posts, processed} ->
      case run_repo_transaction(fn ->
             Enum.map(chunk, fn
               {:post, file} ->
                 {:post,
                  upsert_post_from_rebuild_file(project_id, file,
                    sync_search: false,
                    sync_embeddings: false
                  )}

               {:translation, file} ->
                 {:translation,
                  upsert_post_translation_from_rebuild_file(project_id, file, sync_search: false)}
             end)
           end) do
        {:ok, committed} ->
          Enum.with_index(committed, processed + 1)
          |> Enum.each(fn {_entry, index} ->
            :ok = report_rebuild_progress(on_progress, index, total_files, "post files")
          end)

          chunk_posts = for {:post, post} <- committed, do: post
          {:cont, {:ok, posts ++ chunk_posts, processed + length(chunk)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, posts, _processed} -> {:ok, posts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_repo_transaction(fun) when is_function(fun, 0) do
    Repo.transaction(fun)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
