defmodule BDS.Posts do
  @moduledoc false

  import Ecto.Query

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Embeddings
  alias BDS.AI
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Persistence
  alias BDS.PostLinks
  alias BDS.Posts.Link
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Rebuild
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Slug
  alias BDS.Tasks

  def create_post(attrs) do
    now = Persistence.now_ms()
    project_id = attr(attrs, :project_id)
    title = normalize_title(attr(attrs, :title))
    base_slug = title |> default_slug_source() |> Slug.slugify()

    %Post{}
    |> Post.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      title: title,
      slug: unique_slug(project_id, base_slug),
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
        :ok = maybe_schedule_auto_translations(post)
        {:ok, post}

      error ->
        error
    end
  end

  def update_post(post_id, attrs) do
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
              :ok = maybe_schedule_auto_translations(updated_post)
              {:ok, updated_post}

            error ->
              error
          end
        else
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  def publish_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        project = Projects.get_project!(post.project_id)
        published_at = post.published_at || Persistence.now_ms()
        relative_path = build_post_relative_path(post.slug, post.created_at)
        full_path = Path.join(Projects.project_data_dir(project), relative_path)
        updated_at = Persistence.now_ms()
        body = publishable_post_body(post, full_path, project)

        :ok =
          Persistence.atomic_write(
            full_path,
            serialize_post_file(%{post | updated_at: updated_at, content: body}, published_at)
          )

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
            :ok = publish_post_translations(updated_post)
            :ok = PostLinks.sync_post_links(updated_post)
            :ok = Search.sync_post(updated_post)
            {:ok, updated_post}

          error ->
            error
        end
    end
  end

  def rebuild_posts_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    rebuild_files =
      project
      |> Projects.project_data_dir()
      |> Path.join("posts")
      |> list_matching_files("*.md")
      |> Rebuild.parallel_map(&parse_rebuild_file(project, &1))

    total_files = length(rebuild_files)
    :ok = report_rebuild_started(on_progress, total_files, "post files")

    {translation_files, post_files} = Enum.split_with(rebuild_files, &translation_rebuild_file?/1)

    posts =
      post_files
      |> Enum.with_index(1)
      |> Enum.map(fn {file, index} ->
        post = upsert_post_from_rebuild_file(project_id, file, sync_search: false, sync_embeddings: false)
        :ok = report_rebuild_progress(on_progress, index, total_files, "post files")
        post
      end)

    translation_files
    |> Enum.with_index(length(post_files) + 1)
    |> Enum.each(fn {file, index} ->
      upsert_post_translation_from_rebuild_file(project_id, file, sync_search: false)
      :ok = report_rebuild_progress(on_progress, index, total_files, "post files")
    end)

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
          restored_post = upsert_post_from_file(post.project_id, project, full_path)
          :ok = PostLinks.sync_post_links(restored_post)
          {:ok, restored_post}
        else
          {:error, :not_found}
        end
    end
  end

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
          repaired_post = upsert_post_from_file(post.project_id, project, full_path)
          :ok = PostLinks.sync_post_links(repaired_post)
          {:ok, repaired_post}
        else
          {:error, :not_found}
        end
    end
  end

  def sync_post_translation_from_file(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Translation{} = translation ->
        project = Projects.get_project!(translation.project_id)
        full_path = Path.join(Projects.project_data_dir(project), translation.file_path)

        if File.exists?(full_path) do
          rebuild_file = parse_rebuild_file(project, full_path)
          {:ok, upsert_post_translation_from_rebuild_file(translation.project_id, rebuild_file, sync_search: true)}
        else
          {:error, :not_found}
        end
    end
  end

  def rewrite_published_post_translation(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{file_path: file_path, status: status} = translation
      when file_path not in [nil, ""] and status == :published ->
        post = Repo.get!(Post, translation.translation_for)
        :ok = publish_translation(post, translation)
        {:ok, Repo.get!(Translation, translation_id)}

      %Translation{} ->
        {:error, :not_found}
    end
  end

  def import_orphan_post_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(full_path) do
      rebuild_file = parse_rebuild_file(project, full_path)

      if translation_rebuild_file?(rebuild_file) do
        {:error, :unsupported_file}
      else
        fields =
          rebuild_file.fields
          |> Map.put("id", unique_post_id(Map.get(rebuild_file.fields, "id")))
          |> Map.put("slug", unique_slug_for_import(project_id, Map.fetch!(rebuild_file.fields, "slug")))

        {:ok, upsert_post_from_rebuild_file(project_id, %{rebuild_file | fields: fields})}
      end
    else
      {:error, :not_found}
    end
  end

  def import_orphan_post_translation_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(full_path) do
      rebuild_file = parse_rebuild_file(project, full_path)

      if translation_rebuild_file?(rebuild_file) do
        source_post_id = Map.fetch!(rebuild_file.fields, "translationFor")
        language = normalize_language(Map.fetch!(rebuild_file.fields, "language"))

        case Repo.get(Post, source_post_id) do
          nil ->
            {:error, :not_found}

          %Post{} = post ->
            if normalize_language(post.language) == language or
                 Repo.get_by(Translation, translation_for: source_post_id, language: language) do
              {:error, :conflict}
            else
              fields = Map.put(rebuild_file.fields, "id", Ecto.UUID.generate())
              {:ok, upsert_post_translation_from_rebuild_file(project_id, %{rebuild_file | fields: fields}, sync_search: true)}
            end
        end
      else
        {:error, :unsupported_file}
      end
    else
      {:error, :not_found}
    end
  end

  def delete_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        linked_media_ids = linked_media_ids(post.id)
        delete_post_file(post)
        :ok = Embeddings.remove_post(post.id)
        :ok = PostLinks.delete_post_links(post.id)
        Repo.delete!(post)
        Enum.each(linked_media_ids, &sync_deleted_post_media_sidecar/1)
        :ok = Search.delete_post(post.id)
        {:ok, :deleted}
    end
  end

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

  def get_post!(post_id), do: Repo.get!(Post, post_id)

  def get_post_translation!(translation_id), do: Repo.get!(Translation, translation_id)

  def publish_post_translation(post_id, language) do
    normalized_language = language |> to_string() |> String.trim() |> String.downcase()

    case Repo.get_by(Translation, translation_for: post_id, language: normalized_language) do
      nil ->
        {:error, :not_found}

      %Translation{} ->
        with {:ok, _post} <- publish_post(post_id),
             %Translation{} = translation <- Repo.get_by(Translation, translation_for: post_id, language: normalized_language) do
          {:ok, translation}
        else
          nil -> {:error, :not_found}
          error -> error
        end
    end
  end

  def slug_available(project_id, slug, exclude_post_id \\ nil) do
    normalized_slug = slug |> to_string() |> String.trim()

    query =
      from(post in Post,
        where: post.project_id == ^project_id and post.slug == ^normalized_slug,
        select: post.id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> true
      ^exclude_post_id -> true
      _other -> false
    end
  end

  def unique_slug_for_title(project_id, title, exclude_post_id \\ nil) do
    base_slug = title |> default_slug_source() |> Slug.slugify()

    if slug_available(project_id, base_slug, exclude_post_id) do
      base_slug
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn counter ->
        candidate = "#{base_slug}-#{counter}"
        if slug_available(project_id, candidate, exclude_post_id), do: candidate, else: nil
      end)
    end
  end

  def dashboard_stats(project_id) do
    Repo.all(
      from(post in Post,
        where: post.project_id == ^project_id,
        select: post.status
      )
    )
    |> Enum.reduce(
      %{total_posts: 0, draft_count: 0, published_count: 0, archived_count: 0},
      fn status, acc ->
        acc
        |> Map.update!(:total_posts, &(&1 + 1))
        |> case do
          counts when status == :draft -> Map.update!(counts, :draft_count, &(&1 + 1))
          counts when status == :published -> Map.update!(counts, :published_count, &(&1 + 1))
          counts when status == :archived -> Map.update!(counts, :archived_count, &(&1 + 1))
          counts -> counts
        end
      end
    )
  end

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

  def rebuild_post_links(project_id, opts \\ []) do
    post_ids = Repo.all(from(post in Post, where: post.project_id == ^project_id, select: post.id))
    on_progress = progress_callback(opts)

    Repo.delete_all(
      from(link in Link,
        where: link.source_post_id in ^post_ids or link.target_post_id in ^post_ids
      )
    )

    posts = Repo.all(from(post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at]))
    total_posts = length(posts)
    :ok = report_rebuild_started(on_progress, total_posts, "post links")

    posts
    |> Enum.with_index(1)
    |> Enum.each(fn {post, index} ->
      PostLinks.sync_post_links(post)
      :ok = report_rebuild_progress(on_progress, index, total_posts, "post links")
    end)

    :ok
  end

  def list_post_translations(post_id) do
    {:ok,
     Repo.all(
       from translation in Translation,
         where: translation.translation_for == ^post_id,
         order_by: [asc: translation.language]
     )}
  end

  def upsert_post_translation(post_id, language, attrs) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{do_not_translate: true} = post ->
        {:error,
         post
         |> Post.changeset(%{})
         |> Ecto.Changeset.add_error(
           :do_not_translate,
           "cannot add translations when do_not_translate is true"
         )}

      %Post{} = post ->
        now = Persistence.now_ms()
        normalized_language = normalize_language(language)

        translation =
          Repo.get_by(Translation, translation_for: post.id, language: normalized_language) ||
            %Translation{}

        updates =
          normalize_translation_updates(post, translation, normalized_language, attrs, now)

        translation
        |> Translation.changeset(updates)
        |> Repo.insert_or_update()
        |> case do
          {:ok, saved_translation} ->
            {:ok, _post} = maybe_reopen_source_post_for_manual_translation(post, attrs)
            :ok = Search.sync_post(post.id)
            {:ok, saved_translation}

          error ->
            error
        end
    end
  end

  def delete_post_translation(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{} = translation ->
        :ok = delete_translation_file(translation)
        Repo.delete!(translation)
        :ok = Search.sync_post(translation.translation_for)
        {:ok, :deleted}
    end
  end

  def validate_translations(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    on_progress = progress_callback(opts)

    source_posts =
      Repo.all(
        from post in Post,
          where: post.project_id == ^project_id,
          order_by: [asc: post.created_at, asc: post.slug]
      )

    source_post_map = Map.new(source_posts, &{&1.id, &1})

    translation_rows =
      Repo.all(
        from translation in Translation,
          where: translation.project_id == ^project_id,
          order_by: [asc: translation.translation_for, asc: translation.language, asc: translation.id]
      )

    project_data_dir = Projects.project_data_dir(project)

    markdown_files =
      project_data_dir
      |> Path.join("posts")
      |> list_markdown_files_recursive()

    total_items = length(translation_rows) + length(markdown_files)
    :ok = report_rebuild_started(on_progress, total_items, "translations")

    invalid_database_rows =
      translation_rows
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {translation, index} ->
        :ok = report_rebuild_progress(on_progress, index, total_items, "translations")

        case invalid_database_translation_issue(translation, source_post_map, metadata) do
          nil -> []
          issue -> [issue]
        end
      end)
      |> Enum.sort_by(&translation_validation_issue_sort_key/1)

    {checked_filesystem_file_count, invalid_filesystem_files} =
      markdown_files
      |> Enum.with_index(length(translation_rows) + 1)
      |> Enum.reduce({0, []}, fn {file_path, index}, {count, issues} ->
        :ok = report_rebuild_progress(on_progress, index, total_items, "translations")

        case invalid_filesystem_translation_issue(file_path, source_post_map, metadata) do
          {:ok, nil} ->
            {count + 1, issues}

          {:ok, issue} ->
            {count + 1, [issue | issues]}

          :skip ->
            {count, issues}
        end
      end)

     missing = legacy_missing_translation_entries(source_posts, translation_rows, metadata)
     orphan_files = legacy_orphan_translation_files(invalid_filesystem_files, project_data_dir)
     do_not_translate_posts = legacy_do_not_translate_posts(source_posts)

    {:ok,
     %{
       checked_database_row_count: length(translation_rows),
       checked_filesystem_file_count: checked_filesystem_file_count,
       invalid_database_rows: invalid_database_rows,
       invalid_filesystem_files: Enum.reverse(invalid_filesystem_files) |> Enum.sort_by(&translation_validation_issue_sort_key/1),
       missing: missing,
       orphan_files: orphan_files,
       do_not_translate_posts: do_not_translate_posts
     }}
  end

  def fix_invalid_translations(report) when is_map(report) do
    normalized_report = normalize_translation_validation_report(report)

    {deleted_database_rows, flushed_translations, synced_post_ids} =
      Enum.reduce(normalized_report.invalid_database_rows, {0, 0, MapSet.new()}, fn issue, {deleted, flushed, synced_ids} ->
        case fix_invalid_database_translation(issue) do
          {:deleted, post_id} ->
            {deleted + 1, flushed, maybe_put_synced_post(synced_ids, post_id)}

          {:flushed, post_id} ->
            {deleted, flushed + 1, maybe_put_synced_post(synced_ids, post_id)}

          :noop ->
            {deleted, flushed, synced_ids}
        end
      end)

    deleted_files =
      Enum.reduce(normalized_report.invalid_filesystem_files, 0, fn issue, count ->
        if delete_translation_validation_file(issue.file_path) do
          count + 1
        else
          count
        end
      end)

    Enum.each(synced_post_ids, &Search.sync_post/1)

    {:ok,
     %{
       deleted_database_rows: deleted_database_rows,
       deleted_files: deleted_files,
       flushed_translations: flushed_translations
     }}
  end

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

  defp unique_slug(project_id, base_slug) do
    normalized = if base_slug == "", do: "untitled", else: base_slug

    if slug_available?(project_id, normalized) do
      normalized
    else
      find_unique_slug(project_id, normalized, 2)
    end
  end

  defp find_unique_slug(project_id, base_slug, suffix) do
    candidate = "#{base_slug}-#{suffix}"

    if slug_available?(project_id, candidate) do
      candidate
    else
      find_unique_slug(project_id, base_slug, suffix + 1)
    end
  end

  defp slug_available?(project_id, slug) do
    not Repo.exists?(
      from post in Post, where: post.project_id == ^project_id and post.slug == ^slug
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique_slug_for_import(project_id, slug) do
    normalized = default_slug_source(slug) |> Slug.slugify()

    if slug_available?(project_id, normalized) do
      normalized
    else
      find_unique_slug(project_id, normalized, 2)
    end
  end

  defp unique_post_id(nil), do: Ecto.UUID.generate()

  defp unique_post_id(id) do
    if Repo.get(Post, id) || Repo.get(Translation, id) do
      Ecto.UUID.generate()
    else
      id
    end
  end

  defp normalize_title(nil), do: ""
  defp normalize_title(title), do: title

  defp normalize_optional_title(_title, attrs) do
    if has_attr?(attrs, :title), do: normalize_title(attr(attrs, :title)), else: nil
  end

  defp default_slug_source(""), do: "untitled"
  defp default_slug_source(title), do: title

  defp build_post_relative_path(slug, created_at) do
    datetime = Persistence.from_unix_ms!(created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{slug}.md"])
  end

  defp publishable_post_body(%Post{content: content}, _full_path, _project)
       when is_binary(content), do: content

  defp publishable_post_body(%Post{file_path: file_path} = post, full_path, project) do
    source_path =
      if file_path in [nil, ""] do
        full_path
      else
        Path.join(Projects.project_data_dir(project), file_path)
      end

    published_post_body(post, source_path)
  end

  defp serialize_post_file(post, published_at) do
    Frontmatter.serialize_document(
      [
        {"id", post.id},
        {"title", post.title},
        {"slug", post.slug},
        {"excerpt", post.excerpt},
        {"status", :published},
        {"author", post.author},
        {"language", post.language},
        {"doNotTranslate", post.do_not_translate},
        {"templateSlug", post.template_slug},
        {"createdAt", post.created_at},
        {"updatedAt", post.updated_at},
        {"publishedAt", published_at},
        {"tags", post.tags || []},
        {"categories", post.categories || []}
      ],
      post.content
    )
  end

  defp published_post_body(%Post{content: content}, _full_path) when is_binary(content),
    do: content

  defp published_post_body(_post, full_path), do: read_markdown_body(full_path)

  defp read_markdown_body(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.split(contents, "\n---\n", parts: 2) do
          [_frontmatter, body] -> String.trim_trailing(body, "\n")
          _parts -> ""
        end

      {:error, _reason} ->
        ""
    end
  end

  defp upsert_post_from_file(project_id, project, path) do
    rebuild_file = parse_rebuild_file(project, path)
    upsert_post_from_rebuild_file(project_id, rebuild_file)
  end

  defp upsert_post_from_rebuild_file(project_id, rebuild_file, opts \\ []) do
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

  defp upsert_post_translation_from_rebuild_file(project_id, rebuild_file, opts) do
    fields = rebuild_file.fields
    source_post_id = DocumentFields.fetch!(fields, "translationFor")
    source_post = Repo.get_by!(Post, project_id: project_id, id: source_post_id)
    now = Persistence.now_ms()
    language = normalize_language(DocumentFields.fetch!(fields, "language"))

    translation =
      Repo.get_by(Translation, translation_for: source_post_id, language: language) || %Translation{}

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
      updated_at: DocumentFields.get(fields, "updatedAt", source_post.updated_at || source_post.created_at || now),
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

  defp parse_post_status(status) when is_atom(status), do: status
  defp parse_post_status(status), do: String.to_existing_atom(status)

  defp parse_translation_status(status) when is_atom(status), do: status
  defp parse_translation_status(status), do: String.to_existing_atom(status)

  defp parse_rebuild_file(project, path) do
    contents = File.read!(path)
    {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)

    %{
      path: path,
      relative_path: Path.relative_to(path, Projects.project_data_dir(project)),
      fields: fields
    }
  end

  defp translation_rebuild_file?(%{fields: fields}) do
    DocumentFields.has_key?(fields, "translationFor") and not DocumentFields.has_key?(fields, "slug")
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

  defp delete_post_file(%Post{project_id: _project_id, file_path: file_path})
       when file_path in [nil, ""], do: :ok

  defp delete_post_file(%Post{} = post) do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), post.file_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_translation_updates(post, %Translation{} = translation, language, attrs, now) do
    requested_status =
      case attr(attrs, :status) do
        nil -> nil
        status -> parse_translation_status(status)
      end

    updates =
      %{}
      |> maybe_put(:title, attr(attrs, :title))
      |> maybe_put(:excerpt, attr(attrs, :excerpt))
      |> maybe_put(:content, attr(attrs, :content))

    reopened? =
      translation.status == :published and translation_content_change?(translation, updates)

    status = if(reopened?, do: :draft, else: requested_status || translation.status || :draft)

    %{
      id: translation.id || Ecto.UUID.generate(),
      project_id: post.project_id,
      translation_for: post.id,
      language: language,
      title: Map.get(updates, :title, translation.title),
      excerpt: Map.get(updates, :excerpt, translation.excerpt),
      content: Map.get(updates, :content, translation.content),
      status: status,
      created_at: translation.created_at || now,
      updated_at: now,
      published_at: translation.published_at || if(status == :published, do: now, else: nil),
      file_path: translation.file_path || "",
      checksum: translation.checksum
    }
  end

  defp translation_content_change?(translation, updates) do
    Enum.any?([:title, :excerpt, :content], fn field ->
      case Map.fetch(updates, field) do
        {:ok, value} -> value != Map.get(translation, field)
        :error -> false
      end
    end)
  end

  defp publish_post_translations(%Post{} = post) do
    Repo.all(from translation in Translation, where: translation.translation_for == ^post.id)
    |> Enum.each(fn translation ->
      if translation.status == :draft do
        publish_translation(post, translation)
      end
    end)

    :ok
  end

  defp publish_translation(%Post{} = post, %Translation{} = translation) do
    project = Projects.get_project!(post.project_id)
    published_at = translation.published_at || Persistence.now_ms()
    relative_path = build_translation_relative_path(post, translation.language)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)
    updated_at = Persistence.now_ms()
    body = publishable_translation_body(translation, full_path)

    :ok =
      Persistence.atomic_write(
        full_path,
        serialize_translation_file(
          %{translation | updated_at: updated_at, content: body},
          published_at
        )
      )

    translation
    |> Translation.changeset(%{
      status: :published,
      published_at: published_at,
      file_path: relative_path,
      content: nil,
      updated_at: updated_at
    })
    |> Repo.update!()

    :ok
  end

  defp build_translation_relative_path(post, language) do
    datetime = Persistence.from_unix_ms!(post.created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{post.slug}.#{language}.md"])
  end

  defp serialize_translation_file(translation, published_at) do
    Frontmatter.serialize_document(
      [
        {"id", translation.id},
        {"translationFor", translation.translation_for},
        {"language", translation.language},
        {"title", translation.title},
        {"excerpt", translation.excerpt},
        {"status", :published},
        {"createdAt", translation.created_at},
        {"updatedAt", translation.updated_at},
        {"publishedAt", published_at}
      ],
      translation.content
    )
  end

  defp publishable_translation_body(%Translation{content: content}, _full_path)
       when is_binary(content), do: content

  defp publishable_translation_body(_translation, full_path) do
    case File.read(full_path) do
      {:ok, contents} ->
        case String.split(contents, "\n---\n", parts: 2) do
          [_frontmatter, body] -> String.trim_trailing(body, "\n")
          _parts -> ""
        end

      {:error, _reason} ->
        ""
    end
  end

  defp delete_translation_file(%Translation{project_id: _project_id, file_path: file_path})
       when file_path in [nil, ""], do: :ok

  defp delete_translation_file(%Translation{} = translation) do
    project = Projects.get_project!(translation.project_id)
    full_path = Path.join(Projects.project_data_dir(project), translation.file_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_reopen_source_post_for_manual_translation(%Post{} = post, attrs) do
    if attr(attrs, :auto_generated) == true or post.status != :published or post.file_path in [nil, ""] do
      {:ok, post}
    else
      project = Projects.get_project!(post.project_id)
      full_path = Path.join(Projects.project_data_dir(project), post.file_path)
      restored_content = published_post_body(post, full_path)

      post
      |> Post.changeset(%{
        status: :draft,
        content: restored_content,
        updated_at: Persistence.now_ms()
      })
      |> Repo.update()
    end
  end

  defp maybe_schedule_auto_translations(%Post{do_not_translate: true}), do: :ok

  defp maybe_schedule_auto_translations(%Post{} = post) do
    with true <- auto_translation_configured?(),
         {:ok, metadata} <- Metadata.get_project_metadata(post.project_id) do
      post
      |> missing_auto_translation_languages(metadata)
      |> Enum.each(&queue_post_auto_translation(post, &1))
    else
      _other -> :ok
    end

    :ok
  end

  defp missing_auto_translation_languages(%Post{} = post, metadata) do
    source_language = normalize_language(post.language || metadata.main_language)

    configured_languages =
      ([metadata.main_language] ++ (metadata.blog_languages || []))
      |> Enum.map(&normalize_language/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    existing_languages =
      Repo.all(
        from translation in Translation,
          where: translation.translation_for == ^post.id,
          select: translation.language
      )

    configured_languages
    |> Enum.reject(&(&1 == source_language or &1 in existing_languages))
  end

  defp queue_post_auto_translation(%Post{} = post, language) do
    _ =
      Tasks.submit_task(
        "Auto-translate Post to #{language}",
        fn report ->
          report.(0.05, "Translating post to #{language}")

          with {:ok, translation} <- AI.translate_post(post.id, language, auto_translation_ai_opts()),
               {:ok, saved_translation} <-
                 upsert_post_translation(post.id, language, %{
                   title: translation.title,
                   excerpt: translation.excerpt,
                   content: translation.content,
                   auto_generated: true
                 }) do
            report.(0.85, "Post translation saved")
            :ok = queue_media_translation_cascade(post, language)
            report.(1.0, "Post translation complete")
            %{post_id: post.id, translation_id: saved_translation.id, language: language}
          else
            {:error, reason} -> {:error, reason}
            other -> {:error, other}
          end
        end,
        auto_translation_task_attrs(post)
      )

    :ok
  end

  defp queue_media_translation_cascade(%Post{} = post, language) do
    linked_media_ids(post.id)
    |> Enum.each(fn media_id ->
      if media_translation_needed?(media_id, language) do
        queue_media_translation(post, media_id, language)
      end
    end)

    :ok
  end

  defp queue_media_translation(%Post{} = post, media_id, language) do
    _ =
      Tasks.submit_task(
        "Auto-translate Media to #{language}",
        fn report ->
          report.(0.05, "Translating media to #{language}")

          with {:ok, translation} <- AI.translate_media(media_id, language, auto_translation_ai_opts()),
               {:ok, saved_translation} <-
                 Media.upsert_media_translation(media_id, language, %{
                   title: translation.title,
                   alt: translation.alt,
                   caption: translation.caption
                 }) do
            report.(1.0, "Media translation complete")
            %{media_id: media_id, translation_id: saved_translation.id, language: language}
          else
            {:error, reason} -> {:error, reason}
            other -> {:error, other}
          end
        end,
        auto_translation_task_attrs(post)
      )

    :ok
  end

  defp media_translation_needed?(media_id, language) do
    case Repo.get(Media.Media, media_id) do
      %Media.Media{language: source_language} when source_language not in [nil, ""] and source_language != language ->
        not Repo.exists?(
          from translation in Media.Translation,
            where: translation.translation_for == ^media_id and translation.language == ^language
        )

      _other ->
        false
    end
  end

  defp auto_translation_task_attrs(%Post{} = post) do
    %{
      group_id: post.project_id,
      group_name: "AI"
    }
  end

  defp auto_translation_ai_opts do
    Application.get_env(:bds, :posts, [])
    |> Keyword.get(:auto_translation_ai_opts, [])
  end

  defp auto_translation_configured? do
    mode = if AI.airplane_mode?(), do: :airplane, else: :online

    case AI.get_endpoint(mode) do
      {:ok, %{url: url, model: model} = endpoint}
      when is_binary(url) and url != "" and is_binary(model) and model != "" ->
        mode == :airplane or present?(Map.get(endpoint, :api_key))

      _other ->
        false
    end
  end

  defp linked_media_ids(post_id) do
    case Repo.query("SELECT media_id FROM post_media WHERE post_id = ? ORDER BY sort_order ASC, media_id ASC", [post_id]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [media_id] -> media_id end)
      {:error, _reason} -> []
    end
  end

  defp sync_deleted_post_media_sidecar(media_id) do
    case Media.sync_media_sidecar(media_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp list_markdown_files_recursive(dir) do
    ["*.md", "*.markdown", "*.mdx"]
    |> Enum.flat_map(&list_matching_files(dir, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp invalid_database_translation_issue(%Translation{} = translation, source_post_map, metadata) do
    source_post = Map.get(source_post_map, translation.translation_for)
    normalized_language = normalize_language(translation.language)

    cond do
      is_nil(source_post) ->
        translation_validation_issue(%{
          issue: "missing-source-post",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      canonical_translation_language?(source_post, normalized_language, metadata) ->
        translation_validation_issue(%{
          issue: "same-language-as-canonical",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          canonical_language: canonical_translation_language(source_post, metadata),
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      source_post.do_not_translate ->
        translation_validation_issue(%{
          issue: "do-not-translate-has-translations",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      translation.status == :published and present?(translation.content) ->
        translation_validation_issue(%{
          issue: "content-in-database",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      true ->
        nil
    end
  end

  defp invalid_filesystem_translation_issue(file_path, source_post_map, metadata) do
    with {:ok, contents} <- File.read(file_path),
         {:ok, %{fields: fields}} <- Frontmatter.parse_document(contents),
         true <- translation_rebuild_file?(%{fields: fields}) do
      translation_for = DocumentFields.get(fields, "translationFor")
      source_post = Map.get(source_post_map, translation_for)
      normalized_language = normalize_language(DocumentFields.get(fields, "language"))
      title = DocumentFields.get(fields, "title")

      issue =
        cond do
          is_nil(source_post) ->
            translation_validation_issue(%{
              issue: "missing-source-post",
              translation_for: translation_for,
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          canonical_translation_language?(source_post, normalized_language, metadata) ->
            translation_validation_issue(%{
              issue: "same-language-as-canonical",
              translation_for: translation_for,
              canonical_language: canonical_translation_language(source_post, metadata),
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          source_post.do_not_translate ->
            translation_validation_issue(%{
              issue: "do-not-translate-has-translations",
              translation_for: translation_for,
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          true ->
            nil
        end

      {:ok, issue}
    else
      false -> :skip
      _other -> :skip
    end
  end

  defp normalize_translation_validation_report(report) do
    %{
      checked_database_row_count: map_value(report, :checked_database_row_count, 0),
      checked_filesystem_file_count: map_value(report, :checked_filesystem_file_count, 0),
      invalid_database_rows:
        report
        |> map_value(:invalid_database_rows, [])
        |> Enum.map(&normalize_translation_validation_issue/1),
      invalid_filesystem_files:
        report
        |> map_value(:invalid_filesystem_files, [])
        |> Enum.map(&normalize_translation_validation_issue/1)
    }
  end

  defp legacy_missing_translation_entries(source_posts, translation_rows, metadata) do
    configured_languages =
      ([Map.get(metadata, :main_language)] ++ Map.get(metadata, :blog_languages, []))
      |> Enum.map(&normalize_language/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    existing_languages_by_post =
      Enum.reduce(translation_rows, %{}, fn translation, acc ->
        Map.update(
          acc,
          translation.translation_for,
          MapSet.new([normalize_language(translation.language)]),
          &MapSet.put(&1, normalize_language(translation.language))
        )
      end)

    source_posts
    |> Enum.filter(&(&1.status == :published and not &1.do_not_translate))
    |> Enum.flat_map(fn post ->
      canonical_language = canonical_translation_language(post, metadata)
      existing_languages = Map.get(existing_languages_by_post, post.id, MapSet.new())

      configured_languages
      |> Enum.reject(&(&1 == canonical_language or MapSet.member?(existing_languages, &1)))
      |> Enum.map(&%{post_id: post.id, language: &1})
    end)
    |> Enum.sort_by(&{&1.post_id, &1.language})
  end

  defp legacy_orphan_translation_files(invalid_filesystem_files, project_data_dir) do
    invalid_filesystem_files
    |> Enum.filter(&(Map.get(&1, :issue) == "missing-source-post"))
    |> Enum.map(fn issue ->
      issue
      |> Map.get(:file_path)
      |> relative_project_data_path(project_data_dir)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp legacy_do_not_translate_posts(source_posts) do
    source_posts
    |> Enum.filter(&(&1.status == :published and &1.do_not_translate))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp normalize_translation_validation_issue(issue) when is_map(issue) do
    %{
      issue: map_value(issue, :issue),
      translation_id: blank_to_nil(map_value(issue, :translation_id)),
      translation_for: map_value(issue, :translation_for),
      canonical_language: blank_to_nil(map_value(issue, :canonical_language)),
      translation_language: map_value(issue, :translation_language),
      title: blank_to_nil(map_value(issue, :title)),
      file_path: blank_to_nil(map_value(issue, :file_path))
    }
  end

  defp fix_invalid_database_translation(%{issue: "content-in-database", translation_id: translation_id})
       when is_binary(translation_id) do
    case Repo.get(Translation, translation_id) do
      %Translation{} = translation ->
        case Repo.get(Post, translation.translation_for) do
          %Post{} = post ->
            :ok = publish_translation(post, translation)
            {:flushed, translation.translation_for}

          nil ->
            :noop
        end

      nil ->
        :noop
    end
  end

  defp fix_invalid_database_translation(%{translation_id: translation_id, translation_for: translation_for})
       when is_binary(translation_id) do
    case Repo.get(Translation, translation_id) do
      %Translation{} = translation ->
        Repo.delete!(translation)
        {:deleted, translation_for}

      nil ->
        :noop
    end
  end

  defp fix_invalid_database_translation(_issue), do: :noop

  defp delete_translation_validation_file(file_path) when file_path in [nil, ""], do: false

  defp delete_translation_validation_file(file_path) do
    case File.rm(file_path) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, _reason} -> false
    end
  end

  defp translation_validation_issue(attrs) do
    %{
      issue: Map.get(attrs, :issue),
      translation_id: Map.get(attrs, :translation_id),
      translation_for: Map.get(attrs, :translation_for),
      canonical_language: Map.get(attrs, :canonical_language),
      translation_language: Map.get(attrs, :translation_language),
      title: Map.get(attrs, :title),
      file_path: Map.get(attrs, :file_path)
    }
  end

  defp translation_validation_issue_sort_key(issue) do
    [Map.get(issue, :translation_for), Map.get(issue, :translation_id), Map.get(issue, :file_path)]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join(":")
  end

  defp canonical_translation_language(source_post, metadata) do
    language = normalize_language(source_post.language)

    if language == "" do
      normalize_language(Map.get(metadata, :main_language))
    else
      language
    end
  end

  defp canonical_translation_language?(source_post, language, metadata) do
    canonical_language = canonical_translation_language(source_post, metadata)
    canonical_language != "" and canonical_language == normalize_language(language)
  end

  defp map_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp relative_project_data_path(nil, _project_data_dir), do: nil

  defp relative_project_data_path(file_path, project_data_dir) do
    case Path.relative_to(file_path, project_data_dir) do
      relative_path when relative_path == file_path -> file_path
      relative_path -> relative_path
    end
  end

  defp maybe_put_synced_post(set, post_id) when is_binary(post_id) and post_id != "", do: MapSet.put(set, post_id)
  defp maybe_put_synced_post(set, _post_id), do: set

  defp normalize_language(nil), do: ""

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

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
