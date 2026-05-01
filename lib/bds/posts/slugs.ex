defmodule BDS.Posts.Slugs do
  @moduledoc false

  import Ecto.Query

  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Slug

  @spec available(String.t(), String.t(), String.t() | nil) :: boolean()
  def available(project_id, slug, exclude_post_id \\ nil) do
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

  @spec unique_for_title(String.t(), String.t(), String.t() | nil) :: String.t()
  def unique_for_title(project_id, title, exclude_post_id \\ nil) do
    base_slug = title |> default_source() |> Slug.slugify()

    if available(project_id, base_slug, exclude_post_id) do
      base_slug
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn counter ->
        candidate = "#{base_slug}-#{counter}"
        if available(project_id, candidate, exclude_post_id), do: candidate, else: nil
      end)
    end
  end

  @doc "Pick a free slug, falling back to `untitled` for blank input."
  @spec unique(String.t(), String.t()) :: String.t()
  def unique(project_id, base_slug) do
    normalized = if base_slug == "", do: "untitled", else: base_slug

    if available?(project_id, normalized) do
      normalized
    else
      find_unique(project_id, normalized, 2)
    end
  end

  @doc "Pick a free slug for an imported post by re-slugifying the source value."
  @spec unique_for_import(String.t(), String.t()) :: String.t()
  def unique_for_import(project_id, slug) do
    normalized = slug |> default_source() |> Slug.slugify()

    if available?(project_id, normalized) do
      normalized
    else
      find_unique(project_id, normalized, 2)
    end
  end

  @spec default_source(String.t()) :: String.t()
  def default_source(""), do: "untitled"
  def default_source(title), do: title

  defp find_unique(project_id, base_slug, suffix) do
    candidate = "#{base_slug}-#{suffix}"

    if available?(project_id, candidate) do
      candidate
    else
      find_unique(project_id, base_slug, suffix + 1)
    end
  end

  defp available?(project_id, slug) do
    not Repo.exists?(
      from post in Post, where: post.project_id == ^project_id and post.slug == ^slug
    )
  end
end
