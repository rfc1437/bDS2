defmodule BDS.UI.Dashboard do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags.Tag

  def snapshot(nil), do: empty_snapshot()

  def snapshot(project_id) when is_binary(project_id) do
    posts =
      Repo.all(
        from post in Post,
          where: post.project_id == ^project_id,
          select: %{
            id: post.id,
            title: post.title,
            slug: post.slug,
            status: post.status,
            tags: post.tags,
            categories: post.categories,
            created_at: post.created_at,
            updated_at: post.updated_at
          }
      )

    media_items =
      Repo.all(
        from media in Media,
          where: media.project_id == ^project_id,
          select: %{mime_type: media.mime_type, size: media.size}
      )

    tag_colors =
      Repo.all(
        from tag in Tag,
          where: tag.project_id == ^project_id,
          select: %{name: tag.name, color: tag.color}
      )
      |> Enum.reduce(%{}, fn %{name: name, color: color}, acc ->
        if blank?(color), do: acc, else: Map.put(acc, name, color)
      end)

    post_stats = post_stats(posts)
    media_stats = media_stats(media_items)
    tag_cloud_items = tag_cloud_items(posts, tag_colors)
    category_counts = category_counts(posts)

    %{
      title: "dashboard.title",
      subtitle: "dashboard.subtitle",
      post_stats: post_stats,
      media_stats: media_stats,
      timeline_entries: timeline_entries(posts),
      tag_cloud_items: tag_cloud_items,
      category_counts: category_counts,
      recent_posts: recent_posts(posts)
    }
  end

  def empty_snapshot do
    %{
      title: "dashboard.title",
      subtitle: "dashboard.subtitle",
      post_stats: %{total_posts: 0, draft_count: 0, published_count: 0, archived_count: 0},
      media_stats: %{media_count: 0, image_count: 0, total_bytes: 0},
      timeline_entries: [],
      tag_cloud_items: [],
      category_counts: [],
      recent_posts: []
    }
  end

  defp post_stats(posts) do
    Enum.reduce(
      posts,
      %{total_posts: 0, draft_count: 0, published_count: 0, archived_count: 0},
      fn post, acc ->
        acc
        |> Map.update!(:total_posts, &(&1 + 1))
        |> increment_status(post.status)
      end
    )
  end

  defp media_stats(media_items) do
    Enum.reduce(media_items, %{media_count: 0, image_count: 0, total_bytes: 0}, fn media, acc ->
      acc
      |> Map.update!(:media_count, &(&1 + 1))
      |> Map.update!(:total_bytes, &(&1 + (media.size || 0)))
      |> maybe_increment_image_count(media.mime_type)
    end)
  end

  defp timeline_entries(posts) do
    posts
    |> Enum.reduce(%{}, fn post, acc ->
      datetime = DateTime.from_unix!(post.created_at, :millisecond)
      key = {datetime.year, datetime.month}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{year, month}, count} -> %{year: year, month: month, count: count} end)
    |> Enum.sort_by(&{&1.year, &1.month})
    |> Enum.take(-12)
  end

  defp tag_cloud_items(posts, tag_colors) do
    posts
    |> Enum.flat_map(&normalize_terms(&1.tags))
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count, color: Map.get(tag_colors, tag)} end)
    |> Enum.sort_by(fn %{tag: tag, count: count} -> {-count, String.downcase(tag)} end)
  end

  defp category_counts(posts) do
    posts
    |> Enum.flat_map(&normalize_terms(&1.categories))
    |> Enum.frequencies()
    |> Enum.map(fn {category, count} -> %{category: category, count: count} end)
    |> Enum.sort_by(fn %{category: category, count: count} ->
      {-count, String.downcase(category)}
    end)
  end

  defp recent_posts(posts) do
    posts
    |> Enum.sort_by(& &1.updated_at, :desc)
    |> Enum.take(5)
    |> Enum.map(fn post ->
      %{
        id: post.id,
        title: display_title(post),
        status: Atom.to_string(post.status),
        updated_at: post.updated_at
      }
    end)
  end

  defp normalize_terms(values) do
    values
    |> Kernel.||([])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp display_title(post) do
    if blank?(post.title), do: post.slug || "", else: post.title
  end

  defp increment_status(counts, :draft), do: Map.update!(counts, :draft_count, &(&1 + 1))
  defp increment_status(counts, :published), do: Map.update!(counts, :published_count, &(&1 + 1))
  defp increment_status(counts, :archived), do: Map.update!(counts, :archived_count, &(&1 + 1))
  defp increment_status(counts, _status), do: counts

  defp maybe_increment_image_count(counts, mime_type) when is_binary(mime_type) do
    if String.starts_with?(mime_type, "image/"),
      do: Map.update!(counts, :image_count, &(&1 + 1)),
      else: counts
  end

  defp maybe_increment_image_count(counts, _mime_type), do: counts

  defp blank?(value), do: value in [nil, ""]
end
