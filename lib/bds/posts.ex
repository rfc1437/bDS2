defmodule BDS.Posts do
  @moduledoc """
  Context for blog posts and their translations: create, update, publish, and
  discard changes, plus editor-body resolution.

  Published posts keep their body on the filesystem rather than in the database,
  so `editor_body/1` reads from the post's file when no in-memory content is
  present. Changes are kept in sync with the filesystem and the embeddings index.
  """

  import Ecto.Query
  import BDS.MapUtils, only: [attr: 2, maybe_put: 3]

  alias BDS.Embeddings
  alias BDS.Media
  alias BDS.Persistence
  alias BDS.PostLinks
  alias BDS.Posts.AutoTranslation
  alias BDS.Posts.FileSync
  alias BDS.Posts.Link
  alias BDS.Posts.Post
  alias BDS.Posts.PostMedia
  alias BDS.Posts.RebuildFromFiles
  alias BDS.Posts.Slugs
  alias BDS.Posts.Translation
  alias BDS.Posts.Translations
  alias BDS.Posts.TranslationValidation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Slug

  import FileSync,
    only: [
      post_relative_path: 2,
      publishable_post_body: 3,
      published_post_body: 2,
      read_markdown_body: 1,
      serialize_post_file: 2,
      delete_post_file: 1
    ]

  @typedoc "An attribute map that may use atom or string keys."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @typedoc "Options accepted by long-running rebuild operations."
  @type rebuild_opts :: keyword()

  @typedoc "Aggregate counts returned by `dashboard_stats/1`."
  @type dashboard_stats :: %{
          total_posts: non_neg_integer(),
          draft_count: non_neg_integer(),
          published_count: non_neg_integer(),
          archived_count: non_neg_integer()
        }

  @typedoc "Per-month post count entry returned by `post_counts_by_year_month/1`."
  @type month_count :: %{year: integer(), month: integer(), count: non_neg_integer()}

  @typedoc "Translation validation report returned by `validate_translations/2`."
  @type translation_validation_report :: %{
          checked_database_row_count: non_neg_integer(),
          checked_filesystem_file_count: non_neg_integer(),
          invalid_database_rows: [map()],
          invalid_filesystem_files: [map()],
          missing: [map()],
          orphan_files: [map()],
          do_not_translate_posts: [map()]
        }

  @spec create_post(attrs()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(attrs) do
    now = Persistence.now_ms()
    project_id = attr(attrs, :project_id)
    title = normalize_title(attr(attrs, :title))
    base_slug = title |> Slugs.default_source() |> Slug.slugify()

    %Post{}
    |> Post.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      title: title,
      slug: Slugs.unique(project_id, base_slug),
      excerpt: attr(attrs, :excerpt),
      content: attr(attrs, :content),
      status: :draft,
      author: attr(attrs, :author),
      created_at: now,
      updated_at: now,
      published_at: nil,
      file_path: "",
      checksum: attr(attrs, :checksum),
      tags: attr(attrs, :tags) || [],
      categories: attr(attrs, :categories) || [],
      template_slug: attr(attrs, :template_slug),
      language: attr(attrs, :language),
      do_not_translate: attr(attrs, :do_not_translate) || false,
      published_title: nil,
      published_content: nil,
      published_tags: nil,
      published_categories: nil,
      published_excerpt: nil
    })
    |> Repo.insert()
    |> case do
      {:ok, post} ->
        :ok = Embeddings.sync_post(post)
        :ok = Search.sync_post(post)
        {:ok, post}

      error ->
        error
    end
  end

  @spec update_post(String.t(), attrs(), keyword()) ::
          {:ok, Post.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_post(post_id, attrs, opts \\ []) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      post ->
        with :ok <- validate_slug_change(post, attrs) do
          now = Persistence.now_ms()

          updates =
            attrs
            |> normalize_updates(post)
            |> Map.put(:updated_at, now)
            |> maybe_reopen_published_post(post)

          post
          |> Post.changeset(updates)
          |> Repo.update()
          |> case do
            {:ok, updated_post} ->
              if post.status == :published and updated_post.status == :published and
                   Map.get(updates, :template_slug) != nil and
                   updated_post.template_slug != post.template_slug do
                :ok = rewrite_published_post(updated_post.id)
              end

              :ok = Embeddings.sync_post(updated_post)
              :ok = PostLinks.sync_post_links(updated_post)
              :ok = Search.sync_post(updated_post)

              # Auto-translation only runs on an explicit manual save from the
              # editor, never on post creation or autosave.
              if Keyword.get(opts, :auto_translate, false) do
                :ok = AutoTranslation.maybe_schedule(updated_post)
              end

              {:ok, updated_post}

            error ->
              error
          end
        else
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec publish_post(String.t()) ::
          {:ok, Post.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def publish_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        project = Projects.get_project!(post.project_id)
        published_at = post.published_at || Persistence.now_ms()
        relative_path = post_relative_path(post.slug, post.created_at)
        full_path = Path.join(Projects.project_data_dir(project), relative_path)
        updated_at = Persistence.now_ms()
        body = publishable_post_body(post, full_path, project)

        :ok =
          Persistence.atomic_write(
            full_path,
            serialize_post_file(%{post | updated_at: updated_at, content: body}, published_at)
          )

        if post.file_path != "" and post.file_path != relative_path do
          delete_post_file(post)
        end

        post
        |> Post.changeset(%{
          status: :published,
          published_at: published_at,
          file_path: relative_path,
          content: nil,
          updated_at: updated_at
        })
        |> Repo.update()
        |> case do
          {:ok, updated_post} ->
            :ok = Embeddings.sync_post(updated_post)
            :ok = Translations.publish_post_translations(updated_post)
            :ok = PostLinks.sync_post_links(updated_post)
            :ok = Search.sync_post(updated_post)
            {:ok, updated_post}

          error ->
            error
        end
    end
  end

  @spec rebuild_posts_from_files(String.t(), rebuild_opts()) ::
          {:ok, [Post.t()]} | {:error, term()}
  defdelegate rebuild_posts_from_files(project_id, opts \\ []), to: RebuildFromFiles

  @spec discard_post_changes(String.t()) ::
          {:ok, Post.t()} | {:error, :not_found}
  def discard_post_changes(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Post{} = post ->
        project = Projects.get_project!(post.project_id)
        full_path = Path.join(Projects.project_data_dir(project), post.file_path)

        if File.exists?(full_path) do
          with {:ok, restored_post} <-
                 RebuildFromFiles.upsert_post_from_file(post.project_id, project, full_path) do
            :ok = PostLinks.sync_post_links(restored_post)
            {:ok, restored_post}
          else
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_found}
        end
    end
  end

  @spec editor_body(Post.t() | Translation.t() | term()) :: String.t()
  def editor_body(%Post{content: content}) when is_binary(content), do: content

  def editor_body(%Post{project_id: project_id, file_path: file_path})
      when is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> Path.join(file_path)
    |> read_markdown_body()
  end

  def editor_body(%Translation{content: content}) when is_binary(content), do: content

  def editor_body(%Translation{project_id: project_id, file_path: file_path})
      when is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> Path.join(file_path)
    |> read_markdown_body()
  end

  def editor_body(_record), do: ""

  @spec sync_post_from_file(String.t()) :: {:ok, Post.t()} | {:error, :not_found}
  def sync_post_from_file(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Post{} = post ->
        project = Projects.get_project!(post.project_id)
        full_path = Path.join(Projects.project_data_dir(project), post.file_path)

        if File.exists?(full_path) do
          with {:ok, repaired_post} <-
                 RebuildFromFiles.upsert_post_from_file(post.project_id, project, full_path) do
            :ok = PostLinks.sync_post_links(repaired_post)
            {:ok, repaired_post}
          else
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_found}
        end
    end
  end

  @spec sync_post_translation_from_file(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found}
  defdelegate sync_post_translation_from_file(translation_id), to: Translations

  @spec rewrite_published_post_translation(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found}
  defdelegate rewrite_published_post_translation(translation_id), to: Translations

  @spec import_orphan_post_file(String.t(), String.t()) ::
          {:ok, Post.t()} | {:error, :not_found | :unsupported_file}
  defdelegate import_orphan_post_file(project_id, relative_path), to: RebuildFromFiles

  @spec import_orphan_post_translation_file(String.t(), String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found | :unsupported_file | :conflict}
  defdelegate import_orphan_post_translation_file(project_id, relative_path), to: RebuildFromFiles

  @spec delete_post(String.t()) :: {:ok, :deleted} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        linked_media_ids =
          Repo.all(
            from pm in PostMedia,
              where: pm.post_id == ^post.id,
              order_by: [asc: pm.sort_order, asc: pm.media_id],
              select: pm.media_id
          )

        {:ok, translations} = Translations.list_post_translations(post.id)

        case Repo.delete(post) do
          {:ok, deleted_post} ->
            Enum.each(translations, &FileSync.delete_translation_file/1)
            delete_post_file(deleted_post)
            Embeddings.remove_post(deleted_post.id)
            PostLinks.delete_post_links(deleted_post.id)
            Enum.each(linked_media_ids, &sync_deleted_post_media_sidecar/1)
            Search.delete_post(deleted_post.id)
            {:ok, :deleted}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @spec archive_post(String.t()) ::
          {:ok, Post.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def archive_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{status: status} = post when status in [:draft, :published] ->
        post
        |> Post.changeset(%{status: :archived, updated_at: Persistence.now_ms()})
        |> Repo.update()
        |> case do
          {:ok, updated_post} ->
            :ok = Search.sync_post(updated_post)
            {:ok, updated_post}

          error ->
            error
        end

      %Post{} = post ->
        {:error,
         post
         |> Post.changeset(%{})
         |> Ecto.Changeset.add_error(:status, "cannot archive archived post")}
    end
  end

  @spec unarchive_post(String.t()) ::
          {:ok, Post.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def unarchive_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{status: :archived} = post ->
        content = restore_content_for_unarchive(post)

        post
        |> Post.changeset(%{status: :draft, content: content, updated_at: Persistence.now_ms()})
        |> Repo.update()
        |> case do
          {:ok, updated_post} ->
            :ok = Search.sync_post(updated_post)
            {:ok, updated_post}

          error ->
            error
        end

      %Post{} = post ->
        {:error,
         post
         |> Post.changeset(%{})
         |> Ecto.Changeset.add_error(:status, "cannot unarchive non-archived post")}
    end
  end

  @spec get_post!(String.t()) :: Post.t()
  @spec get_post(String.t()) :: Post.t() | nil
  def get_post(post_id), do: Repo.get(Post, post_id)

  def get_post!(post_id), do: Repo.get!(Post, post_id)

  @spec get_post_translation!(String.t()) :: Translation.t()
  def get_post_translation!(translation_id), do: Repo.get!(Translation, translation_id)

  @spec publish_post_translation(String.t(), String.t() | atom()) ::
          {:ok, Translation.t()} | {:error, :not_found | term()}
  defdelegate publish_post_translation(post_id, language), to: Translations

  @spec slug_available(String.t(), String.t(), String.t() | nil) :: boolean()
  defdelegate slug_available(project_id, slug, exclude_post_id \\ nil),
    to: Slugs,
    as: :available

  @spec unique_slug_for_title(String.t(), String.t(), String.t() | nil) :: String.t()
  defdelegate unique_slug_for_title(project_id, title, exclude_post_id \\ nil),
    to: Slugs,
    as: :unique_for_title

  @spec dashboard_stats(String.t()) :: dashboard_stats()
  def dashboard_stats(project_id) do
    Repo.all(
      from(post in Post,
        where: post.project_id == ^project_id,
        group_by: post.status,
        select: {post.status, count(post.id)}
      )
    )
    |> Enum.reduce(
      %{total_posts: 0, draft_count: 0, published_count: 0, archived_count: 0},
      fn
        {:draft, n}, acc -> %{acc | total_posts: acc.total_posts + n, draft_count: n}
        {:published, n}, acc -> %{acc | total_posts: acc.total_posts + n, published_count: n}
        {:archived, n}, acc -> %{acc | total_posts: acc.total_posts + n, archived_count: n}
        {_other, n}, acc -> %{acc | total_posts: acc.total_posts + n}
      end
    )
  end

  @spec post_counts_by_year_month(String.t()) :: [month_count()]
  def post_counts_by_year_month(project_id) do
    Repo.all(
      from(post in Post,
        where: post.project_id == ^project_id,
        select: post.created_at
      )
    )
    |> Enum.reduce(%{}, fn created_at, acc ->
      datetime = DateTime.from_unix!(created_at, :millisecond)
      key = {datetime.year, datetime.month}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{year, month}, count} -> %{year: year, month: month, count: count} end)
    |> Enum.sort_by(fn %{year: year, month: month} -> {-year, -month} end)
  end

  @spec rebuild_post_links(String.t(), rebuild_opts()) :: :ok
  def rebuild_post_links(project_id, opts \\ []) do
    post_ids =
      Repo.all(from(post in Post, where: post.project_id == ^project_id, select: post.id))

    on_progress = RebuildFromFiles.progress_callback(opts)

    Repo.delete_all(
      from(link in Link,
        where: link.source_post_id in ^post_ids or link.target_post_id in ^post_ids
      )
    )

    posts =
      Repo.all(
        from(post in Post,
          where: post.project_id == ^project_id,
          order_by: [asc: post.created_at]
        )
      )

    total_posts = length(posts)
    :ok = RebuildFromFiles.report_rebuild_started(on_progress, total_posts, "post links")

    posts
    |> Enum.with_index(1)
    |> Enum.each(fn {post, index} ->
      PostLinks.sync_post_links(post)

      :ok =
        RebuildFromFiles.report_rebuild_progress(on_progress, index, total_posts, "post links")
    end)

    :ok
  end

  @spec list_post_translations(String.t()) :: {:ok, [Translation.t()]}
  defdelegate list_post_translations(post_id), to: Translations

  @spec upsert_post_translation(String.t(), String.t() | atom(), attrs()) ::
          {:ok, Translation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  defdelegate upsert_post_translation(post_id, language, attrs), to: Translations

  @spec delete_post_translation(String.t()) :: {:ok, :deleted} | {:error, :not_found}
  defdelegate delete_post_translation(translation_id), to: Translations

  @spec validate_translations(String.t(), rebuild_opts()) ::
          {:ok, translation_validation_report()}
  defdelegate validate_translations(project_id, opts \\ []),
    to: TranslationValidation,
    as: :validate

  @spec fix_invalid_translations(map()) ::
          {:ok,
           %{
             deleted_database_rows: non_neg_integer(),
             deleted_files: non_neg_integer(),
             flushed_translations: non_neg_integer()
           }}
  defdelegate fix_invalid_translations(report), to: TranslationValidation, as: :fix_invalid

  @spec fill_missing_translations(String.t(), rebuild_opts()) ::
          {:ok,
           %{
             translated_posts: non_neg_integer(),
             translated_media: non_neg_integer(),
             failed_count: non_neg_integer(),
             warned_count: non_neg_integer(),
             nothing_to_do: boolean()
           }}
  defdelegate fill_missing_translations(project_id, opts \\ []),
    to: AutoTranslation,
    as: :fill_missing

  @spec rewrite_published_post(String.t()) :: :ok
  def rewrite_published_post(post_id) do
    post = Repo.get!(Post, post_id)

    if post.status == :published and post.file_path not in [nil, ""] do
      project = Projects.get_project!(post.project_id)
      full_path = Path.join(Projects.project_data_dir(project), post.file_path)
      body = published_post_body(post, full_path)

      :ok =
        Persistence.atomic_write(
          full_path,
          serialize_post_file(
            %{post | content: body},
            post.published_at || Persistence.now_ms()
          )
        )
    end

    :ok
  end

  defp normalize_updates(attrs, _post) do
    %{}
    |> maybe_put(:title, normalize_optional_title(attr(attrs, :title), attrs))
    |> maybe_put(:slug, attr(attrs, :slug))
    |> maybe_put(:excerpt, attr(attrs, :excerpt))
    |> maybe_put(:content, attr(attrs, :content))
    |> maybe_put(:status, attr(attrs, :status))
    |> maybe_put(:author, attr(attrs, :author))
    |> maybe_put(:published_at, attr(attrs, :published_at))
    |> maybe_put(:file_path, attr(attrs, :file_path))
    |> maybe_put(:checksum, attr(attrs, :checksum))
    |> maybe_put(:tags, attr(attrs, :tags))
    |> maybe_put(:categories, attr(attrs, :categories))
    |> maybe_put(:template_slug, attr(attrs, :template_slug))
    |> maybe_put(:language, attr(attrs, :language))
    |> maybe_put(:do_not_translate, attr(attrs, :do_not_translate))
    |> maybe_put(:published_title, attr(attrs, :published_title))
    |> maybe_put(:published_content, attr(attrs, :published_content))
    |> maybe_put(:published_tags, attr(attrs, :published_tags))
    |> maybe_put(:published_categories, attr(attrs, :published_categories))
    |> maybe_put(:published_excerpt, attr(attrs, :published_excerpt))
  end

  defp validate_slug_change(%Post{published_at: published_at} = post, attrs)
       when not is_nil(published_at) do
    case attr(attrs, :slug) do
      nil ->
        :ok

      slug when slug == post.slug ->
        :ok

      _slug ->
        {:error,
         post
         |> Post.changeset(%{})
         |> Ecto.Changeset.add_error(:slug, "cannot change slug after first publish")}
    end
  end

  defp validate_slug_change(_post, _attrs), do: :ok

  defp maybe_reopen_published_post(updates, %Post{status: :published} = post) do
    if published_content_change?(updates, post) do
      Map.put(updates, :status, :draft)
    else
      updates
    end
  end

  defp maybe_reopen_published_post(updates, _post), do: updates

  defp published_content_change?(updates, post) do
    Enum.any?(
      [
        :title,
        :excerpt,
        :content,
        :author,
        :language,
        :tags,
        :categories,
        :do_not_translate
      ],
      fn field ->
        case Map.fetch(updates, field) do
          {:ok, value} -> value != Map.get(post, field)
          :error -> false
        end
      end
    )
  end

  defp restore_content_for_unarchive(%Post{content: content}) when is_binary(content), do: content

  defp restore_content_for_unarchive(%Post{file_path: file_path} = post)
       when file_path not in [nil, ""] do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), file_path)
    read_markdown_body(full_path)
  end

  defp restore_content_for_unarchive(_post), do: ""

  defp normalize_title(nil), do: ""
  defp normalize_title(title), do: title

  defp normalize_optional_title(_title, attrs) do
    if has_attr?(attrs, :title), do: normalize_title(attr(attrs, :title)), else: nil
  end

  defp sync_deleted_post_media_sidecar(media_id) do
    case Media.sync_media_sidecar(media_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end
end
