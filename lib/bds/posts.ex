defmodule BDS.Posts do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
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
            :ok = publish_post_translations(updated_post)
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

  def get_post_translation!(translation_id), do: Repo.get!(Translation, translation_id)

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
         |> Ecto.Changeset.add_error(:do_not_translate, "cannot add translations when do_not_translate is true")}

      %Post{} = post ->
        now = System.system_time(:second)
        normalized_language = normalize_language(language)

        translation =
          Repo.get_by(Translation, translation_for: post.id, language: normalized_language) || %Translation{}

        updates = normalize_translation_updates(post, translation, normalized_language, attrs, now)

        translation
        |> Translation.changeset(updates)
        |> Repo.insert_or_update()
        |> case do
          {:ok, saved_translation} ->
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

  def validate_translations(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    posts =
      Repo.all(
        from post in Post,
          where: post.project_id == ^project_id and post.status == :published,
          order_by: [asc: post.created_at, asc: post.slug]
      )

    translation_languages =
      Repo.all(
        from translation in Translation,
          join: post in Post,
          on: post.id == translation.translation_for,
          where: post.project_id == ^project_id,
          select: {translation.translation_for, translation.language}
      )
      |> Enum.group_by(fn {post_id, _language} -> post_id end, fn {_post_id, language} -> language end)

    required_languages =
      metadata.blog_languages
      |> Enum.map(&normalize_language/1)
      |> Enum.reject(&(&1 == normalize_language(metadata.main_language)))
      |> Enum.uniq()
      |> Enum.sort()

    missing =
      posts
      |> Enum.flat_map(fn post ->
        available = Map.get(translation_languages, post.id, [])

        cond do
          post.do_not_translate -> []
          true ->
            required_languages
            |> Enum.reject(&(&1 in available))
            |> Enum.map(&%{post_id: post.id, language: &1})
        end
      end)

    do_not_translate_posts =
      posts
      |> Enum.filter(& &1.do_not_translate)
      |> Enum.map(& &1.id)

    orphan_files = orphan_translation_files(project_id)

    {:ok,
     %{
       missing: missing,
       orphan_files: orphan_files,
       do_not_translate_posts: do_not_translate_posts
     }}
  end

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

  defp normalize_translation_updates(post, %Translation{} = translation, language, attrs, now) do
    updates =
      %{}
      |> maybe_put(:title, attr(attrs, :title))
      |> maybe_put(:excerpt, attr(attrs, :excerpt))
      |> maybe_put(:content, attr(attrs, :content))

    reopened? = translation.status == :published and translation_content_change?(translation, updates)

    %{
      id: translation.id || Ecto.UUID.generate(),
      project_id: post.project_id,
      translation_for: post.id,
      language: language,
      title: Map.get(updates, :title, translation.title),
      excerpt: Map.get(updates, :excerpt, translation.excerpt),
      content: Map.get(updates, :content, translation.content),
      status: if(reopened?, do: :draft, else: translation.status || :draft),
      created_at: translation.created_at || now,
      updated_at: now,
      published_at: translation.published_at,
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
    published_at = translation.published_at || System.system_time(:second)
    relative_path = build_translation_relative_path(post, translation.language)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)
    updated_at = System.system_time(:second)
    body = publishable_translation_body(translation, full_path)

    :ok = File.mkdir_p(Path.dirname(full_path))
    :ok = File.write(full_path, serialize_translation_file(%{translation | updated_at: updated_at, content: body}, published_at))

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
    datetime = DateTime.from_unix!(post.created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{post.slug}.#{language}.md"])
  end

  defp serialize_translation_file(translation, published_at) do
    Frontmatter.serialize_document(
      [
        {:id, translation.id},
        {:translation_for, translation.translation_for},
        {:language, translation.language},
        {:title, translation.title},
        {:excerpt, translation.excerpt},
        {:status, :published},
        {:created_at, translation.created_at},
        {:updated_at, translation.updated_at},
        {:published_at, published_at}
      ],
      translation.content || ""
    )
  end

  defp publishable_translation_body(%Translation{content: content}, _full_path) when is_binary(content), do: content

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

  defp delete_translation_file(%Translation{project_id: _project_id, file_path: file_path}) when file_path in [nil, ""], do: :ok

  defp delete_translation_file(%Translation{} = translation) do
    project = Projects.get_project!(translation.project_id)
    full_path = Path.join(Projects.project_data_dir(project), translation.file_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp orphan_translation_files(project_id) do
    project = Projects.get_project!(project_id)
    translation_paths = MapSet.new(Repo.all(from translation in Translation, where: translation.project_id == ^project_id, select: translation.file_path))

    project
    |> Projects.project_data_dir()
    |> Path.join("posts")
    |> list_matching_files("*.md")
    |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
    |> Enum.filter(&translation_file?/1)
    |> Enum.reject(&MapSet.member?(translation_paths, &1))
    |> Enum.sort()
  end

  defp translation_file?(relative_path) do
    Regex.match?(~r/\.[a-z]{2}\.md$/i, relative_path)
  end

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
end
