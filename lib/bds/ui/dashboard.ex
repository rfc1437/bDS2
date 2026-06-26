defmodule BDS.UI.Dashboard do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags.Tag

  @spec snapshot(String.t() | nil) :: map()
  def snapshot(nil), do: empty_snapshot()

  def snapshot(project_id) when is_binary(project_id) do
    %{
      title: "dashboard.title",
      subtitle: "dashboard.subtitle",
      post_stats: post_stats(project_id),
      media_stats: media_stats(project_id),
      timeline_entries: timeline_entries(project_id),
      tag_cloud_items: tag_cloud_items(project_id),
      category_counts: category_counts(project_id),
      recent_posts: recent_posts(project_id)
    }
  end

  @spec empty_snapshot() :: map()
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

  defp post_stats(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        group_by: post.status,
        select: {post.status, count(post.id)}
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

  defp media_stats(project_id) do
    {media_count, total_bytes} =
      Repo.one(
        from media in Media,
          where: media.project_id == ^project_id,
          select: {count(media.id), coalesce(sum(media.size), 0)}
      )

    image_count =
      Repo.one(
        from media in Media,
          where: media.project_id == ^project_id and like(media.mime_type, "image/%"),
          select: count(media.id)
      )

    %{media_count: media_count, image_count: image_count, total_bytes: total_bytes}
  end

  defp timeline_entries(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        group_by: [
          fragment(
            "CAST(strftime('%Y', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
            post.created_at
          ),
          fragment(
            "CAST(strftime('%m', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
            post.created_at
          )
        ],
        select: %{
          year:
            fragment(
              "CAST(strftime('%Y', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
              post.created_at
            ),
          month:
            fragment(
              "CAST(strftime('%m', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
              post.created_at
            ),
          count: count(post.id)
        },
        order_by: [
          asc:
            fragment(
              "CAST(strftime('%Y', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
              post.created_at
            ),
          asc:
            fragment(
              "CAST(strftime('%m', datetime(? / 1000, 'unixepoch')) AS INTEGER)",
              post.created_at
            )
        ]
    )
    |> Enum.take(-12)
  end

  defp tag_cloud_items(project_id) do
    tag_colors =
      Repo.all(
        from tag in Tag,
          where: tag.project_id == ^project_id,
          where: not is_nil(tag.color) and tag.color != "",
          select: {tag.name, tag.color}
      )
      |> Map.new()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT trim(je.value) AS tag, COUNT(*) AS cnt
        FROM posts, json_each(posts.tags) je
        WHERE posts.project_id = ?1
          AND trim(je.value) != ''
        GROUP BY tag
        ORDER BY cnt DESC, lower(tag) ASC
        """,
        [project_id]
      )

    Enum.map(rows, fn [tag, count] ->
      %{tag: tag, count: count, color: Map.get(tag_colors, tag)}
    end)
  end

  defp category_counts(project_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT trim(je.value) AS category, COUNT(*) AS cnt
        FROM posts, json_each(posts.categories) je
        WHERE posts.project_id = ?1
          AND trim(je.value) != ''
        GROUP BY category
        ORDER BY cnt DESC, lower(category) ASC
        """,
        [project_id]
      )

    Enum.map(rows, fn [category, count] ->
      %{category: category, count: count}
    end)
  end

  defp recent_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at],
        limit: 5,
        select: %{
          id: post.id,
          title: post.title,
          slug: post.slug,
          status: post.status,
          updated_at: post.updated_at
        }
    )
    |> Enum.map(fn post ->
      %{
        id: post.id,
        title: display_title(post),
        status: Atom.to_string(post.status),
        updated_at: post.updated_at
      }
    end)
  end

  defp display_title(post) do
    if blank?(post.title), do: post.slug || "", else: post.title
  end

  defp blank?(value), do: BDS.Values.blank?(value)
end
