defmodule BDS.Scripting.Capabilities.Posts do
  @moduledoc false

  import Ecto.Query
  import BDS.Scripting.Capabilities.Util

  alias BDS.PostLinks
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Preview
  alias BDS.Repo
  alias BDS.Search

  def create_post(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Posts.create_post()
    |> unwrap_result(&post_payload/1)
  end

  def update_post(project_id, post_id, attrs) do
    case fetch_post(project_id, post_id) do
      %Post{} ->
        Posts.update_post(post_id, normalize_map(attrs)) |> unwrap_result(&post_payload/1)

      _other ->
        nil
    end
  end

  def delete_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> boolean_result(Posts.delete_post(post_id))
      _other -> false
    end
  end

  def load_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} = post -> post_payload(post)
      _other -> nil
    end
  end

  def list_posts(project_id) do
    Repo.all(
      from(post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at])
    )
    |> Enum.map(&post_payload/1)
  end

  def load_post_by_slug(project_id, slug) do
    Repo.one(
      from(post in Post,
        where: post.project_id == ^project_id and post.slug == ^(string_or_nil(slug) || ""),
        limit: 1
      )
    )
    |> case do
      %Post{} = post -> post_payload(post)
      nil -> nil
    end
  end

  def publish_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.publish_post(post_id) |> unwrap_result(&post_payload/1)
      _other -> nil
    end
  end

  def discard_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.discard_post_changes(post_id) |> unwrap_result(&post_payload/1)
      _other -> nil
    end
  end

  def filter_posts(project_id, filters) do
    project_id
    |> Search.search_posts("", normalize_search_filters(filters))
    |> unwrap_result(fn %{posts: posts} -> Enum.map(posts, &post_payload/1) end)
  end

  def generate_unique_post_slug(project_id, title, exclude_post_id) do
    Posts.unique_slug_for_title(
      project_id,
      string_or_nil(title) || "",
      string_or_nil(exclude_post_id)
    )
  end

  def posts_by_status(project_id, status) do
    normalized_status = string_or_nil(status) || ""

    Repo.all(
      from(post in Post,
        where:
          post.project_id == ^project_id and
            fragment("CAST(? AS TEXT) = ?", post.status, ^normalized_status),
        order_by: [asc: post.created_at]
      )
    )
    |> Enum.map(&post_payload/1)
  end

  def post_counts_by_year_month(project_id) do
    Posts.post_counts_by_year_month(project_id)
    |> sanitize()
  end

  def post_dashboard_stats(project_id) do
    Posts.dashboard_stats(project_id)
    |> sanitize()
  end

  def linked_posts_for(project_id, post_id, direction) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} -> linked_posts(id, direction)
      _other -> []
    end
  end

  def preview_url(project_id, post_id, options) do
    case fetch_post(project_id, post_id) do
      %Post{} = post ->
        with {:ok, server} <- Preview.start_preview(project_id) do
          base_url = "http://#{server.host}:#{server.port}"
          canonical_path = canonical_preview_path(post.created_at, post.slug)
          options = normalize_map(options)
          language = options |> Map.get("lang") |> string_or_nil() |> blank_to_nil()

          query =
            %{}
            |> maybe_put_query("draft", truthy?(Map.get(options, "draft")) && "true")
            |> maybe_put_query("post_id", truthy?(Map.get(options, "draft")) && post.id)
            |> maybe_put_query("lang", language)

          if map_size(query) == 0 do
            base_url <> canonical_path
          else
            base_url <> canonical_path <> "?" <> URI.encode_query(query)
          end
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  def post_slug_available?(project_id, slug, exclude_post_id) do
    Posts.slug_available(project_id, string_or_nil(slug) || "", string_or_nil(exclude_post_id))
  end

  def publish_post_translation(project_id, post_id, language) do
    case fetch_post(project_id, post_id) do
      %Post{} ->
        Posts.publish_post_translation(post_id, string_or_nil(language) || "") |> unwrap_result()

      _other ->
        nil
    end
  end

  def rebuild_post_links(project_id) do
    case Posts.rebuild_post_links(project_id) do
      :ok -> true
    end
  end

  def rebuild_posts_from_files(project_id) do
    project_id
    |> Posts.rebuild_posts_from_files()
    |> unwrap_result(fn posts -> Enum.map(posts, &post_payload/1) end)
  end

  def reindex_project_search(project_id) do
    case Search.reindex_project(project_id) do
      :ok -> true
    end
  end

  def search_posts(project_id, query) do
    project_id
    |> Search.search_posts(string_or_nil(query) || "")
    |> unwrap_result(fn %{posts: posts} -> Enum.map(posts, &post_payload/1) end)
  end

  def post_tags(project_id), do: names_with_counts(project_id, :tags) |> Enum.map(& &1["name"])
  def post_tags_with_counts(project_id), do: names_with_counts(project_id, :tags)

  def post_categories(project_id),
    do: names_with_counts(project_id, :categories) |> Enum.map(& &1["name"])

  def post_categories_with_counts(project_id), do: names_with_counts(project_id, :categories)

  def list_post_translations(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} ->
        id
        |> Posts.list_post_translations()
        |> unwrap_result(fn translations -> Enum.map(translations, &sanitize/1) end)

      _other ->
        []
    end
  end

  def load_post_translation(project_id, post_id, language) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} ->
        Repo.one(
          from(translation in PostTranslation,
            where:
              translation.translation_for == ^id and
                translation.language == ^(string_or_nil(language) || ""),
            limit: 1
          )
        )
        |> sanitize_nilable()

      _other ->
        nil
    end
  end

  def has_published_post_version(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{status: :published} ->
        true

      %Post{published_at: published_at, file_path: file_path} ->
        not is_nil(published_at) or file_path not in [nil, ""]

      _other ->
        false
    end
  end

  def fetch_post(project_id, post_id) do
    Repo.one(
      from(post in Post,
        where: post.project_id == ^project_id and post.id == ^(string_or_nil(post_id) || ""),
        limit: 1
      )
    )
  end

  def post_payload(%Post{} = post) do
    post
    |> sanitize()
    |> Map.put("backlinks", linked_posts(post.id, :incoming))
    |> Map.put("links_to", linked_posts(post.id, :outgoing))
  end

  def linked_posts(post_id, :incoming) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&load_linked_post(&1.source_post_id))
    |> Enum.reject(&is_nil/1)
  end

  def linked_posts(post_id, :outgoing) do
    PostLinks.list_outgoing_links(post_id)
    |> Enum.map(&load_linked_post(&1.target_post_id))
    |> Enum.reject(&is_nil/1)
  end

  defp load_linked_post(post_id) do
    case Repo.get(Post, post_id) do
      %Post{} = post -> %{"id" => post.id, "title" => post.title, "slug" => post.slug}
      nil -> nil
    end
  end

  defp canonical_preview_path(created_at_ms, slug) do
    datetime = DateTime.from_unix!(created_at_ms, :millisecond)
    "/#{datetime.year}/#{pad2(datetime.month)}/#{pad2(datetime.day)}/#{string_or_nil(slug) || ""}"
  end

  def names_with_counts(project_id, field) when field in [:tags, :categories] do
    column = Atom.to_string(field)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT trim(je.value) AS name, COUNT(*) AS cnt " <>
          "FROM posts, json_each(posts.#{column}) je " <>
          "WHERE posts.project_id = ?1 AND trim(je.value) != '' " <>
          "GROUP BY name ORDER BY lower(name), cnt",
        [project_id]
      )

    Enum.map(rows, fn [name, count] -> %{"name" => name, "count" => count} end)
  end
end
