defmodule BDS.Posts.FileSync do
  @moduledoc false

  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Projects

  @doc "Compute the canonical relative path for a published post."
  @spec post_relative_path(String.t(), integer()) :: String.t()
  def post_relative_path(slug, created_at) do
    datetime = Persistence.from_unix_ms!(created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{slug}.md"])
  end

  @doc "Compute the canonical relative path for a translation file."
  @spec translation_relative_path(Post.t(), String.t()) :: String.t()
  def translation_relative_path(post, language) do
    datetime = Persistence.from_unix_ms!(post.created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["posts", year, month, "#{post.slug}.#{language}.md"])
  end

  @doc "Resolve the body to publish for a post, falling back to its existing file."
  @spec publishable_post_body(Post.t(), String.t(), term()) :: String.t()
  def publishable_post_body(%Post{content: content}, _full_path, _project)
      when is_binary(content), do: content

  def publishable_post_body(%Post{file_path: file_path} = post, full_path, project) do
    source_path =
      if file_path in [nil, ""] do
        full_path
      else
        Path.join(Projects.project_data_dir(project), file_path)
      end

    published_post_body(post, source_path)
  end

  @doc "Read the body of a previously-published post (DB content first, file fallback)."
  @spec published_post_body(Post.t(), String.t()) :: String.t()
  def published_post_body(%Post{content: content}, _full_path) when is_binary(content),
    do: content

  def published_post_body(_post, full_path), do: read_markdown_body(full_path)

  @doc "Read the body section (after frontmatter) from a markdown file on disk."
  @spec read_markdown_body(String.t()) :: String.t()
  def read_markdown_body(path) do
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

  @doc "Serialize a post to a frontmatter+body string for the published file."
  @spec serialize_post_file(Post.t(), integer()) :: String.t()
  def serialize_post_file(post, published_at) do
    Frontmatter.serialize_document(
      [
        {"id", post.id},
        {"title", post.title},
        {"slug", post.slug},
        {"excerpt", post.excerpt},
        {"status", :published},
        {"author", post.author},
        {"language", post.language},
        {"doNotTranslate", post.do_not_translate || nil},
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

  @doc "Serialize a translation row to a frontmatter+body string."
  @spec serialize_translation_file(Translation.t(), integer()) :: String.t()
  def serialize_translation_file(translation, published_at) do
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

  @doc "Resolve the body of a translation, falling back to its existing file."
  @spec publishable_translation_body(Translation.t(), String.t()) :: String.t()
  def publishable_translation_body(%Translation{content: content}, _full_path)
      when is_binary(content), do: content

  def publishable_translation_body(_translation, full_path) do
    read_markdown_body(full_path)
  end

  @doc "Delete a published post's file on disk (no-op if it has none)."
  @spec delete_post_file(Post.t()) :: :ok | {:error, term()}
  def delete_post_file(%Post{file_path: file_path}) when file_path in [nil, ""], do: :ok

  def delete_post_file(%Post{} = post) do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), post.file_path)
    rm_quiet(full_path)
  end

  @doc "Delete a translation's file on disk (no-op if it has none)."
  @spec delete_translation_file(Translation.t()) :: :ok | {:error, term()}
  def delete_translation_file(%Translation{file_path: file_path}) when file_path in [nil, ""],
    do: :ok

  def delete_translation_file(%Translation{} = translation) do
    project = Projects.get_project!(translation.project_id)
    full_path = Path.join(Projects.project_data_dir(project), translation.file_path)
    rm_quiet(full_path)
  end

  defp rm_quiet(full_path) do
    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
