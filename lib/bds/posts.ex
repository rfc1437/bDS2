defmodule BDS.Posts do
  @moduledoc false

  import Ecto.Query

  alias BDS.Posts.Post
  alias BDS.Repo
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
        else
          {:error, changeset} -> {:error, changeset}
        end
    end
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

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
