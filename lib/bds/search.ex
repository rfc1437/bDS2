defmodule BDS.Search do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  def search_posts(project_id, query, filters \\ %{}) do
    filters = normalize_filters(filters)

    posts =
      project_id
      |> candidate_post_ids(query)
      |> load_posts_in_order()
      |> filter_posts(filters)

    {:ok,
     %{
       posts: paginate(posts, filters),
       total: length(posts),
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  def search_media(project_id, query, filters \\ %{}) do
    filters = normalize_filters(filters)

    media_items =
      project_id
      |> candidate_media_ids(query)
      |> load_media_in_order()

    {:ok,
     %{
       media: paginate(media_items, filters),
       total: length(media_items),
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  def reindex_project(project_id) do
    Repo.query!("DELETE FROM posts_fts WHERE post_id IN (SELECT id FROM posts WHERE project_id = ?)", [project_id])
    Repo.query!("DELETE FROM media_fts WHERE media_id IN (SELECT id FROM media WHERE project_id = ?)", [project_id])

    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.each(&sync_post/1)

    Repo.all(from media in Media, where: media.project_id == ^project_id)
    |> Enum.each(&sync_media/1)

    :ok
  end

  def sync_post(%Post{} = post) do
    delete_post(post.id)

    {title, excerpt, content, tags, categories} = post_index_fields(post)

    Repo.query!(
      "INSERT INTO posts_fts (post_id, title, excerpt, content, tags, categories) VALUES (?, ?, ?, ?, ?, ?)",
      [post.id, title, excerpt, content, tags, categories]
    )

    :ok
  end

  def sync_post(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil -> delete_post(post_id)
      post -> sync_post(post)
    end
  end

  def delete_post(%Post{id: post_id}), do: delete_post(post_id)

  def delete_post(post_id) when is_binary(post_id) do
    Repo.query!("DELETE FROM posts_fts WHERE post_id = ?", [post_id])
    :ok
  end

  def sync_media(%Media{} = media) do
    delete_media(media.id)

    {title, alt, caption, original_name, tags} = media_index_fields(media)

    Repo.query!(
      "INSERT INTO media_fts (media_id, title, alt, caption, original_name, tags) VALUES (?, ?, ?, ?, ?, ?)",
      [media.id, title, alt, caption, original_name, tags]
    )

    :ok
  end

  def sync_media(media_id) when is_binary(media_id) do
    case Repo.get(Media, media_id) do
      nil -> delete_media(media_id)
      media -> sync_media(media)
    end
  end

  def delete_media(%Media{id: media_id}), do: delete_media(media_id)

  def delete_media(media_id) when is_binary(media_id) do
    Repo.query!("DELETE FROM media_fts WHERE media_id = ?", [media_id])
    :ok
  end

  defp candidate_post_ids(project_id, query) do
    if blank_query?(query) do
      Repo.all(from post in Post, where: post.project_id == ^project_id, select: post.id)
    else
      Repo.query!(
        """
        SELECT posts_fts.post_id
        FROM posts_fts
        JOIN posts ON posts.id = posts_fts.post_id
        WHERE posts.project_id = ? AND posts_fts MATCH ?
        ORDER BY bm25(posts_fts), posts_fts.rowid
        """,
        [project_id, query]
      ).rows
      |> Enum.map(fn [post_id] -> post_id end)
    end
  end

  defp candidate_media_ids(project_id, query) do
    if blank_query?(query) do
      Repo.all(from media in Media, where: media.project_id == ^project_id, select: media.id)
    else
      Repo.query!(
        """
        SELECT media_fts.media_id
        FROM media_fts
        JOIN media ON media.id = media_fts.media_id
        WHERE media.project_id = ? AND media_fts MATCH ?
        ORDER BY bm25(media_fts), media_fts.rowid
        """,
        [project_id, query]
      ).rows
      |> Enum.map(fn [media_id] -> media_id end)
    end
  end

  defp load_posts_in_order([]), do: []

  defp load_posts_in_order(post_ids) do
    posts_by_id =
      Repo.all(from post in Post, where: post.id in ^post_ids)
      |> Map.new(&{&1.id, &1})

    Enum.map(post_ids, &Map.get(posts_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp load_media_in_order([]), do: []

  defp load_media_in_order(media_ids) do
    media_by_id =
      Repo.all(from media in Media, where: media.id in ^media_ids)
      |> Map.new(&{&1.id, &1})

    Enum.map(media_ids, &Map.get(media_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp filter_posts(posts, filters) do
    translation_languages =
      if is_binary(filters.missing_translation_language) do
        post_translation_languages(posts)
      else
        %{}
      end

    Enum.filter(posts, fn post ->
      matches_status?(post, filters.status) and
        matches_overlap?(post.tags, filters.tags) and
        matches_overlap?(post.categories, filters.categories) and
        matches_exact?(post.language, filters.language) and
        matches_year?(post, filters.year) and
        matches_month?(post, filters.month) and
        matches_from?(post, filters.from) and
        matches_to?(post, filters.to) and
        matches_missing_translation?(post, filters.missing_translation_language, translation_languages)
    end)
  end

  defp matches_status?(_post, nil), do: true
  defp matches_status?(post, status), do: to_string(post.status) == to_string(status)

  defp matches_overlap?(_values, []), do: true

  defp matches_overlap?(values, required_values) do
    not MapSet.disjoint?(MapSet.new(values || []), MapSet.new(required_values))
  end

  defp matches_exact?(_value, nil), do: true
  defp matches_exact?(value, expected), do: value == expected

  defp matches_year?(_post, nil), do: true
  defp matches_year?(post, year), do: DateTime.from_unix!(post.created_at).year == year

  defp matches_month?(_post, nil), do: true
  defp matches_month?(post, month), do: DateTime.from_unix!(post.created_at).month == month

  defp matches_from?(_post, nil), do: true
  defp matches_from?(post, from_unix), do: post.created_at >= from_unix

  defp matches_to?(_post, nil), do: true
  defp matches_to?(post, to_unix), do: post.created_at <= to_unix

  defp matches_missing_translation?(_post, nil, _translation_languages), do: true
  defp matches_missing_translation?(%Post{do_not_translate: true}, _language, _translation_languages), do: false

  defp matches_missing_translation?(post, language, translation_languages) do
    language not in Map.get(translation_languages, post.id, [])
  end

  defp post_translation_languages([]), do: %{}

  defp post_translation_languages(posts) do
    post_ids = Enum.map(posts, & &1.id)
    placeholders = Enum.map_join(post_ids, ",", fn _ -> "?" end)

    Repo.query!(
      "SELECT translation_for, language FROM post_translations WHERE translation_for IN (#{placeholders})",
      post_ids
    ).rows
    |> Enum.group_by(fn [post_id, _language] -> post_id end, fn [_post_id, language] -> language end)
  end

  defp paginate(items, filters) do
    items
    |> Enum.drop(filters.offset)
    |> Enum.take(filters.limit)
  end

  defp post_index_fields(post) do
    translations = post_translations(post.id)

    title = [post.title | Enum.map(translations, &Map.get(&1, "title"))] |> join_text()
    excerpt = [post.excerpt | Enum.map(translations, &Map.get(&1, "excerpt"))] |> join_text()

    content =
      [post_content(post) | Enum.map(translations, &translation_content(post.project_id, &1))]
      |> join_text()

    tags = Enum.join(post.tags || [], " ")
    categories = Enum.join(post.categories || [], " ")

    {title, excerpt, content, tags, categories}
  end

  defp media_index_fields(media) do
    translations =
      Repo.all(from translation in MediaTranslation, where: translation.translation_for == ^media.id)

    title = [media.title | Enum.map(translations, & &1.title)] |> join_text()
    alt = [media.alt | Enum.map(translations, & &1.alt)] |> join_text()
    caption = [media.caption | Enum.map(translations, & &1.caption)] |> join_text()
    original_name = media.original_name || ""
    tags = Enum.join(media.tags || [], " ")

    {title, alt, caption, original_name, tags}
  end

  defp post_translations(post_id) do
    Repo.query!(
      "SELECT language, title, excerpt, content, status, file_path FROM post_translations WHERE translation_for = ?",
      [post_id]
    ).rows
    |> Enum.map(fn [language, title, excerpt, content, status, file_path] ->
      %{
        "language" => language,
        "title" => title,
        "excerpt" => excerpt,
        "content" => content,
        "status" => status,
        "file_path" => file_path
      }
    end)
  end

  defp post_content(%Post{content: content}) when is_binary(content), do: content

  defp post_content(%Post{project_id: project_id, file_path: file_path}) when is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> Path.join(file_path)
    |> markdown_body_from_file()
  end

  defp post_content(_post), do: ""

  defp translation_content(_project_id, %{"content" => content}) when is_binary(content), do: content

  defp translation_content(project_id, %{"status" => "published", "file_path" => file_path}) when is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> Path.join(file_path)
    |> markdown_body_from_file()
  end

  defp translation_content(_project_id, _translation), do: ""

  defp markdown_body_from_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.split(contents, "\n---\n", parts: 2) do
          [_frontmatter, body] -> String.trim_trailing(body, "\n")
          _parts -> contents
        end

      {:error, _reason} ->
        ""
    end
  end

  defp join_text(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp normalize_filters(filters) do
    %{
      status: attr(filters, :status),
      tags: normalize_list_filter(attr(filters, :tags)),
      categories: normalize_list_filter(attr(filters, :categories)),
      language: attr(filters, :language),
      missing_translation_language: attr(filters, :missing_translation_language),
      year: normalize_integer(attr(filters, :year)),
      month: normalize_integer(attr(filters, :month)),
      from: normalize_timestamp(attr(filters, :from), :start),
      to: normalize_timestamp(attr(filters, :to), :end),
      offset: normalize_non_negative_integer(attr(filters, :offset), 0),
      limit: normalize_non_negative_integer(attr(filters, :limit), 50)
    }
  end

  defp normalize_list_filter(nil), do: []
  defp normalize_list_filter(value) when is_list(value), do: Enum.reject(value, &is_nil/1)
  defp normalize_list_filter(value), do: [value]

  defp normalize_integer(nil), do: nil
  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_non_negative_integer(nil, default), do: default
  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(value, default), do: normalize_integer(value) || default

  defp normalize_timestamp(nil, _position), do: nil
  defp normalize_timestamp(value, _position) when is_integer(value), do: value

  defp normalize_timestamp(value, position) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        time = if position == :start, do: ~T[00:00:00], else: ~T[23:59:59]
        {:ok, datetime} = DateTime.new(date, time, "Etc/UTC")
        DateTime.to_unix(datetime)

      {:error, _reason} -> nil
    end
  end

  defp blank_query?(query), do: query in [nil, ""] or String.trim(to_string(query)) == ""

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
