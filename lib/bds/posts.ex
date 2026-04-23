defmodule BDS.Posts do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Slug

  def create_post(attrs) do
    now = System.system_time(:second)
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
      do_not_translate: false,
      published_title: nil,
      published_content: nil,
      published_tags: nil,
      published_categories: nil,
      published_excerpt: nil
    })
    |> Repo.insert()
    |> case do
      {:ok, post} ->
        :ok = Search.sync_post(post)
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
          now = System.system_time(:second)
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
              :ok = Search.sync_post(updated_post)
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
        published_at = post.published_at || System.system_time(:second)
        relative_path = build_post_relative_path(post.slug, post.created_at)
        full_path = Path.join(Projects.project_data_dir(project), relative_path)
        updated_at = System.system_time(:second)
        body = publishable_post_body(post, full_path, project)

        :ok = File.mkdir_p(Path.dirname(full_path))
        :ok = File.write(full_path, serialize_post_file(%{post | updated_at: updated_at, content: body}, published_at))

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
            :ok = Search.sync_post(updated_post)
            {:ok, updated_post}

          error ->
            error
        end
    end
  end

  def rebuild_posts_from_files(project_id) do
    project = Projects.get_project!(project_id)

    posts =
      project
      |> Projects.project_data_dir()
      |> Path.join("posts")
      |> list_matching_files("*.md")
      |> Enum.map(&upsert_post_from_file(project_id, project, &1))

    {:ok, posts}
  end

  def delete_post(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        delete_post_file(post)
        Repo.delete!(post)
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
        |> Post.changeset(%{status: :archived, updated_at: System.system_time(:second)})
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

  def rewrite_published_post(post_id) do
    post = Repo.get!(Post, post_id)

    if post.status == :published and post.file_path not in [nil, ""] do
      project = Projects.get_project!(post.project_id)
      full_path = Path.join(Projects.project_data_dir(project), post.file_path)
      body = published_post_body(post, full_path)
      :ok = File.mkdir_p(Path.dirname(full_path))
      :ok = File.write(full_path, serialize_post_file(%{post | content: body}, post.published_at || System.system_time(:second)))
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

  defp validate_slug_change(%Post{published_at: published_at} = post, attrs) when not is_nil(published_at) do
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
    Enum.any?([:title, :excerpt, :content, :author, :language, :template_slug, :tags, :categories, :do_not_translate], fn field ->
      case Map.fetch(updates, field) do
        {:ok, value} -> value != Map.get(post, field)
        :error -> false
      end
    end)
  end

  defp unique_slug(project_id, base_slug) do
    normalized = if base_slug in [nil, ""], do: "untitled", else: base_slug

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
    not Repo.exists?(from post in Post, where: post.project_id == ^project_id and post.slug == ^slug)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_title(nil), do: ""
  defp normalize_title(title), do: title

  defp normalize_optional_title(_title, attrs) do
    if has_attr?(attrs, :title), do: normalize_title(attr(attrs, :title)), else: nil
  end

  defp default_slug_source(""), do: "untitled"
  defp default_slug_source(title), do: title

  defp build_post_relative_path(slug, created_at) do
    datetime = DateTime.from_unix!(created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{slug}.md"])
  end

  defp publishable_post_body(%Post{content: content}, _full_path, _project) when is_binary(content), do: content

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
        {:id, post.id},
        {:title, post.title},
        {:slug, post.slug},
        {:excerpt, post.excerpt},
        {:status, :published},
        {:author, post.author},
        {:language, post.language},
        {:do_not_translate, post.do_not_translate},
        {:template_slug, post.template_slug},
        {:created_at, post.created_at},
        {:updated_at, post.updated_at},
        {:published_at, published_at},
        {:tags, post.tags || []},
        {:categories, post.categories || []}
      ],
      post.content || ""
    )
  end

  defp published_post_body(%Post{content: content}, _full_path) when is_binary(content), do: content

  defp published_post_body(_post, full_path) do
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

  defp upsert_post_from_file(project_id, project, path) do
    contents = File.read!(path)
    {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)
    relative_path = Path.relative_to(path, Projects.project_data_dir(project))
    now = System.system_time(:second)

    attrs = %{
      id: Map.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      title: Map.get(fields, "title") || "",
      slug: Map.fetch!(fields, "slug"),
      excerpt: Map.get(fields, "excerpt"),
      content: nil,
      status: parse_post_status(Map.get(fields, "status", "published")),
      author: Map.get(fields, "author"),
      created_at: Map.get(fields, "created_at", now),
      updated_at: Map.get(fields, "updated_at", now),
      published_at: Map.get(fields, "published_at"),
      file_path: relative_path,
      checksum: nil,
      tags: Map.get(fields, "tags", []),
      categories: Map.get(fields, "categories", []),
      template_slug: Map.get(fields, "template_slug"),
      language: Map.get(fields, "language"),
      do_not_translate: Map.get(fields, "do_not_translate", false),
      published_title: nil,
      published_content: nil,
      published_tags: nil,
      published_categories: nil,
      published_excerpt: nil
    }

    post = Repo.get_by(Post, project_id: project_id, slug: attrs.slug) || %Post{}

    post
    |> Post.changeset(attrs)
    |> Repo.insert_or_update!()
    |> tap(&Search.sync_post/1)
  end

  defp parse_post_status(status) when is_atom(status), do: status
  defp parse_post_status(status), do: String.to_existing_atom(status)

  defp list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join([dir, "**", pattern])
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  defp delete_post_file(%Post{project_id: _project_id, file_path: file_path}) when file_path in [nil, ""], do: :ok

  defp delete_post_file(%Post{} = post) do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), post.file_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
end
