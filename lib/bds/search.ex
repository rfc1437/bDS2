defmodule BDS.Search do
  @moduledoc false

  import Ecto.Query
  import BDS.MapUtils, only: [attr: 2]

  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Persistence
  alias BDS.Posts.Post
  alias BDS.ProgressReporter
  alias BDS.Projects
  alias BDS.Repo

  @stemmer_languages [
    "ar",
    "ca",
    "da",
    "de",
    "el",
    "en",
    "es",
    "eu",
    "fi",
    "fr",
    "ga",
    "hi",
    "hu",
    "hy",
    "it",
    "lt",
    "ne",
    "nl",
    "no",
    "pt",
    "ro",
    "ru",
    "sv",
    "tr"
  ]

  @stemmer_algorithms %{
    "da" => :danish,
    "nl" => :dutch,
    "en" => :english,
    "fi" => :finnish,
    "fr" => :french,
    "de" => :german,
    "hu" => :hungarian,
    "it" => :italian,
    "no" => :norwegian,
    "pt" => :portuguese,
    "ro" => :romanian,
    "ru" => :russian,
    "es" => :spanish,
    "sv" => :swedish,
    "tr" => :turkish
  }

  @language_hints [
    {"de", ~w(der die das und ein eine ist sind läuft laufen morgen fluss entlang)},
    {"fr", ~w(je tu il elle nous vous ils elles le la les un une des courir cours matin travail)},
    {"es", ~w(el la los las un una unos unas y que para con pero)},
    {"it", ~w(il lo la gli le un una uno e che per con ogni mattina)}
  ]

  @typedoc "Filters and pagination accepted by the search functions."
  @type search_filters :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @typedoc "Reindex/long-running progress options."
  @type reindex_opts :: keyword()

  @spec list_stemmer_languages() :: [String.t()]
  def list_stemmer_languages do
    @stemmer_languages
  end

  @spec detect_language(String.t() | nil) :: String.t()
  def detect_language(text) do
    normalized_text = text |> to_string() |> String.downcase()

    cond do
      normalized_text == "" -> "en"
      String.match?(normalized_text, ~r/[äöüß]/u) -> "de"
      String.match?(normalized_text, ~r/[àâçéèêëîïôùûüÿœ]/u) -> "fr"
      String.match?(normalized_text, ~r/[ñ¡¿]/u) -> "es"
      true -> detect_language_from_hints(normalized_text)
    end
  end

  @spec stem(String.t() | nil, String.t() | nil) :: String.t()
  def stem(text, language \\ nil) do
    language = normalize_language(language || detect_language(text))

    text
    |> tokenize_text()
    |> Enum.map_join(" ", &stem_token(&1, language))
  end

  @spec search_posts(String.t(), String.t() | nil, search_filters()) ::
          {:ok,
           %{
             posts: [Post.t()],
             total: non_neg_integer(),
             offset: non_neg_integer(),
             limit: non_neg_integer()
           }}
  def search_posts(project_id, query, filters \\ %{}) do
    filters = normalize_filters(filters)

    if blank_query?(query) do
      search_posts_blank(project_id, filters)
    else
      search_posts_fts(project_id, query, filters)
    end
  end

  defp search_posts_blank(project_id, filters) do
    base = from(post in Post, where: post.project_id == ^project_id)
    filtered = apply_post_filters(base, filters)
    total = count_query(filtered)

    posts =
      filtered
      |> order_by([p], desc: p.created_at)
      |> limit(^filters.limit)
      |> offset(^filters.offset)
      |> Repo.all()

    {:ok,
     %{
       posts: posts,
       total: total,
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  defp search_posts_fts(project_id, query_text, filters) do
    match_query = build_match_query(query_text, filters.language)

    fts_subquery =
      from(f in fragment("posts_fts"),
        where: fragment("posts_fts MATCH ?", ^match_query),
        order_by: fragment("bm25(posts_fts), rowid"),
        select: %{post_id: f.post_id, fts_rowid: fragment("rowid")}
      )

    base =
      Post
      |> with_cte("fts_results", as: ^fts_subquery)
      |> join(:inner, [p], fts in "fts_results", on: fts.post_id == p.id)
      |> where([p], p.project_id == ^project_id)

    filtered = apply_post_filters(base, filters)
    total = count_query(filtered)

    posts =
      filtered
      |> order_by([_, fts], fts.fts_rowid)
      |> limit(^filters.limit)
      |> offset(^filters.offset)
      |> Repo.all()

    {:ok,
     %{
       posts: posts,
       total: total,
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  @spec search_media(String.t(), String.t() | nil, search_filters()) ::
          {:ok,
           %{
             media: [Media.t()],
             total: non_neg_integer(),
             offset: non_neg_integer(),
             limit: non_neg_integer()
           }}
  def search_media(project_id, query, filters \\ %{}) do
    filters = normalize_filters(filters)

    if blank_query?(query) do
      search_media_blank(project_id, filters)
    else
      search_media_fts(project_id, query, filters)
    end
  end

  defp search_media_blank(project_id, filters) do
    base = from(media in Media, where: media.project_id == ^project_id)
    filtered = apply_media_filters(base, filters)
    total = count_query(filtered)

    media_items =
      filtered
      |> order_by([m], desc: m.created_at)
      |> limit(^filters.limit)
      |> offset(^filters.offset)
      |> Repo.all()

    {:ok,
     %{
       media: media_items,
       total: total,
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  defp search_media_fts(project_id, query_text, filters) do
    match_query = build_match_query(query_text, filters.language)

    fts_subquery =
      from(f in fragment("media_fts"),
        where: fragment("media_fts MATCH ?", ^match_query),
        order_by: fragment("bm25(media_fts), rowid"),
        select: %{media_id: f.media_id, fts_rowid: fragment("rowid")}
      )

    base =
      Media
      |> with_cte("fts_results", as: ^fts_subquery)
      |> join(:inner, [m], fts in "fts_results", on: fts.media_id == m.id)
      |> where([m], m.project_id == ^project_id)

    filtered = apply_media_filters(base, filters)
    total = count_query(filtered)

    media_items =
      filtered
      |> order_by([_, fts], fts.fts_rowid)
      |> limit(^filters.limit)
      |> offset(^filters.offset)
      |> Repo.all()

    {:ok,
     %{
       media: media_items,
       total: total,
       offset: filters.offset,
       limit: filters.limit
     }}
  end

  defp count_query(query) do
    query
    |> select([r], count(r.id))
    |> Repo.one() || 0
  end

  defp apply_post_filters(query, filters) do
    query
    |> maybe_where_status(filters.status)
    |> maybe_where_language(filters.language)
    |> maybe_where_year(filters.year)
    |> maybe_where_month(filters.month)
    |> maybe_where_from(filters.from)
    |> maybe_where_to(filters.to)
    |> maybe_where_tags(filters.tags)
    |> maybe_where_categories(filters.categories)
    |> maybe_where_missing_translation(filters.missing_translation_language)
  end

  defp apply_media_filters(query, filters) do
    query
    |> maybe_where_language(filters.language)
    |> maybe_where_year(filters.year)
    |> maybe_where_month(filters.month)
    |> maybe_where_from(filters.from)
    |> maybe_where_to(filters.to)
    |> maybe_where_tags_media(filters.tags)
  end

  defp maybe_where_status(query, nil), do: query
  defp maybe_where_status(query, status), do: where(query, [p], p.status == ^to_string(status))

  defp maybe_where_language(query, nil), do: query
  defp maybe_where_language(query, language), do: where(query, [p], p.language == ^language)

  defp maybe_where_year(query, nil), do: query

  defp maybe_where_year(query, year) do
    year_str = to_string(year)

    where(
      query,
      [p],
      fragment("strftime('%Y', datetime(? / 1000, 'unixepoch')) = ?", p.created_at, ^year_str)
    )
  end

  defp maybe_where_month(query, nil), do: query

  defp maybe_where_month(query, month) do
    month_str = String.pad_leading(to_string(month), 2, "0")

    where(
      query,
      [p],
      fragment("strftime('%m', datetime(? / 1000, 'unixepoch')) = ?", p.created_at, ^month_str)
    )
  end

  defp maybe_where_from(query, nil), do: query
  defp maybe_where_from(query, from), do: where(query, [p], p.created_at >= ^from)

  defp maybe_where_to(query, nil), do: query
  defp maybe_where_to(query, to), do: where(query, [p], p.created_at <= ^to)

  defp maybe_where_tags(query, []), do: query

  defp maybe_where_tags(query, tags) do
    tags_clause =
      Enum.reduce(tags, false, fn tag, acc ->
        dynamic(
          [p],
          ^acc or fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)", p.tags, ^tag)
        )
      end)

    where(query, [p], ^tags_clause)
  end

  defp maybe_where_tags_media(query, []), do: query

  defp maybe_where_tags_media(query, tags) do
    tags_clause =
      Enum.reduce(tags, false, fn tag, acc ->
        dynamic(
          [m],
          ^acc or fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)", m.tags, ^tag)
        )
      end)

    where(query, [m], ^tags_clause)
  end

  defp maybe_where_categories(query, []), do: query

  defp maybe_where_categories(query, categories) do
    categories_clause =
      Enum.reduce(categories, false, fn category, acc ->
        dynamic(
          [p],
          ^acc or
            fragment(
              "EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)",
              p.categories,
              ^category
            )
        )
      end)

    where(query, [p], ^categories_clause)
  end

  defp maybe_where_missing_translation(query, nil), do: query

  defp maybe_where_missing_translation(query, language) do
    where(
      query,
      [p],
      p.do_not_translate == false and
        fragment(
          "NOT EXISTS (SELECT 1 FROM post_translations WHERE translation_for = ? AND language = ?)",
          p.id,
          ^language
        )
    )
  end

  @spec reindex_project(String.t()) :: :ok
  def reindex_project(project_id) do
    :ok = reindex_posts(project_id)
    :ok = reindex_media(project_id)

    :ok
  end

  @spec reindex_posts(String.t(), reindex_opts()) :: :ok
  def reindex_posts(project_id, opts \\ []) do
    Repo.query!(
      "DELETE FROM posts_fts WHERE post_id IN (SELECT id FROM posts WHERE project_id = ?)",
      [project_id]
    )

    posts = Repo.all(from post in Post, where: post.project_id == ^project_id)

    post_ids = Enum.map(posts, & &1.id)
    translations_by_post_id = preload_post_translations(post_ids)

    on_progress = progress_callback(opts)
    total_posts = length(posts)

    :ok = report_reindex_started(on_progress, total_posts, "posts")

    rows =
      posts
      |> Enum.with_index(1)
      |> Enum.map(fn {post, index} ->
        translations = Map.get(translations_by_post_id, post.id, [])
        :ok = report_reindex_progress(on_progress, index, total_posts, "posts")
        post_index_row(post, translations)
      end)

    batch_insert_post_index(rows)

    :ok
  end

  @spec reindex_media(String.t(), reindex_opts()) :: :ok
  def reindex_media(project_id, opts \\ []) do
    Repo.query!(
      "DELETE FROM media_fts WHERE media_id IN (SELECT id FROM media WHERE project_id = ?)",
      [project_id]
    )

    media_items = Repo.all(from media in Media, where: media.project_id == ^project_id)

    media_ids = Enum.map(media_items, & &1.id)
    translations_by_media_id = preload_media_translations(media_ids)

    on_progress = progress_callback(opts)
    total_media = length(media_items)

    :ok = report_reindex_started(on_progress, total_media, "media items")

    rows =
      media_items
      |> Enum.with_index(1)
      |> Enum.map(fn {media, index} ->
        translations = Map.get(translations_by_media_id, media.id, [])
        :ok = report_reindex_progress(on_progress, index, total_media, "media items")
        media_index_row(media, translations)
      end)

    batch_insert_media_index(rows)

    :ok
  end

  @spec sync_post(Post.t() | String.t()) :: :ok
  def sync_post(%Post{} = post) do
    delete_post(post.id)
    insert_post_index(post)
    :ok
  end

  def sync_post(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil -> delete_post(post_id)
      post -> sync_post(post)
    end
  end

  @spec delete_post(Post.t() | String.t()) :: :ok
  def delete_post(%Post{id: post_id}), do: delete_post(post_id)

  def delete_post(post_id) when is_binary(post_id) do
    Repo.query!("DELETE FROM posts_fts WHERE post_id = ?", [post_id])
    :ok
  end

  @spec sync_media(Media.t() | String.t()) :: :ok
  def sync_media(%Media{} = media) do
    delete_media(media.id)
    insert_media_index(media)
    :ok
  end

  def sync_media(media_id) when is_binary(media_id) do
    case Repo.get(Media, media_id) do
      nil -> delete_media(media_id)
      media -> sync_media(media)
    end
  end

  @spec delete_media(Media.t() | String.t()) :: :ok
  def delete_media(%Media{id: media_id}), do: delete_media(media_id)

  def delete_media(media_id) when is_binary(media_id) do
    Repo.query!("DELETE FROM media_fts WHERE media_id = ?", [media_id])
    :ok
  end

  defp progress_callback(opts), do: ProgressReporter.callback(opts)

  defp report_reindex_started(callback, total, label) do
    ProgressReporter.report_count_started(callback, total, label,
      verb: "Reindexing",
      start_progress: 0.0,
      empty_suffix: "to reindex",
      message_style: :prefix_count
    )
  end

  defp report_reindex_progress(callback, current, total, label) do
    ProgressReporter.report_count_progress(callback, current, total, label,
      verb: "Reindexing",
      start_progress: 0.0,
      message_style: :prefix_count
    )
  end

  defp post_index_row(%Post{} = post, translations) do
    {title, excerpt, content, tags, categories} = post_index_fields(post, translations)
    [post.id, title, excerpt, content, tags, categories]
  end

  defp media_index_row(%Media{} = media, translations) do
    {title, alt, caption, original_name, tags} = media_index_fields(media, translations)
    [media.id, title, alt, caption, original_name, tags]
  end

  # SQLite allows up to 999 bound parameters per statement.
  # Posts have 6 columns → max 166 rows per batch.
  @post_batch_size 166
  @media_batch_size 166

  defp batch_insert_post_index([]), do: :ok

  defp batch_insert_post_index(rows) do
    rows
    |> Enum.chunk_every(@post_batch_size)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end)
      params = List.flatten(chunk)

      Repo.query!(
        "INSERT INTO posts_fts (post_id, title, excerpt, content, tags, categories) VALUES #{placeholders}",
        params
      )
    end)
  end

  defp batch_insert_media_index([]), do: :ok

  defp batch_insert_media_index(rows) do
    rows
    |> Enum.chunk_every(@media_batch_size)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end)
      params = List.flatten(chunk)

      Repo.query!(
        "INSERT INTO media_fts (media_id, title, alt, caption, original_name, tags) VALUES #{placeholders}",
        params
      )
    end)
  end

  defp insert_post_index(%Post{} = post) do
    translations = post_translations(post.id)
    row = post_index_row(post, translations)

    Repo.query!(
      "INSERT INTO posts_fts (post_id, title, excerpt, content, tags, categories) VALUES (?, ?, ?, ?, ?, ?)",
      row
    )
  end

  defp insert_media_index(%Media{} = media) do
    translations = media_translations(media.id)
    row = media_index_row(media, translations)

    Repo.query!(
      "INSERT INTO media_fts (media_id, title, alt, caption, original_name, tags) VALUES (?, ?, ?, ?, ?, ?)",
      row
    )
  end

  defp post_index_fields(post, translations) do
    post_language = normalize_language(post.language)

    title =
      [
        stem(post.title, post_language)
        | Enum.map(translations, &stem(Map.get(&1, "title"), Map.get(&1, "language")))
      ]
      |> join_text()

    excerpt =
      [
        stem(post.excerpt, post_language)
        | Enum.map(translations, &stem(Map.get(&1, "excerpt"), Map.get(&1, "language")))
      ]
      |> join_text()

    content =
      [
        stem(post_content(post), post_language)
        | Enum.map(
            translations,
            &stem(translation_content(post.project_id, &1), Map.get(&1, "language"))
          )
      ]
      |> join_text()

    tags = stem(Enum.join(post.tags || [], " "), post_language)
    categories = stem(Enum.join(post.categories || [], " "), post_language)

    {title, excerpt, content, tags, categories}
  end

  defp media_index_fields(media, translations) do
    media_language = normalize_language(media.language)

    title =
      [stem(media.title, media_language) | Enum.map(translations, &stem(&1.title, &1.language))]
      |> join_text()

    alt =
      [stem(media.alt, media_language) | Enum.map(translations, &stem(&1.alt, &1.language))]
      |> join_text()

    caption =
      [
        stem(media.caption, media_language)
        | Enum.map(translations, &stem(&1.caption, &1.language))
      ]
      |> join_text()

    original_name = stem(media.original_name || "", media_language)
    tags = stem(Enum.join(media.tags || [], " "), media_language)

    {title, alt, caption, original_name, tags}
  end

  defp preload_post_translations(post_ids) when is_list(post_ids) do
    if Enum.empty?(post_ids) do
      %{}
    else
      placeholders = Enum.map_join(post_ids, ", ", fn _ -> "?" end)

      Repo.query!(
        "SELECT translation_for, language, title, excerpt, content, status, file_path FROM post_translations WHERE translation_for IN (#{placeholders})",
        post_ids
      ).rows
      |> Enum.group_by(
        fn [post_id | _] -> post_id end,
        fn [_post_id, language, title, excerpt, content, status, file_path] ->
          %{
            "language" => language,
            "title" => title,
            "excerpt" => excerpt,
            "content" => content,
            "status" => status,
            "file_path" => file_path
          }
        end
      )
    end
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

  defp preload_media_translations(media_ids) when is_list(media_ids) do
    if Enum.empty?(media_ids) do
      %{}
    else
      Repo.all(
        from translation in MediaTranslation,
          where: translation.translation_for in ^media_ids,
          select: {translation.translation_for, translation}
      )
      |> Enum.group_by(fn {media_id, _} -> media_id end, fn {_, translation} -> translation end)
    end
  end

  defp media_translations(media_id) do
    Repo.all(
      from translation in MediaTranslation, where: translation.translation_for == ^media_id
    )
  end

  defp post_content(%Post{content: content}) when is_binary(content), do: content

  defp post_content(%Post{project_id: project_id, file_path: file_path})
       when is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> Path.join(file_path)
    |> markdown_body_from_file()
  end

  defp post_content(_post), do: ""

  defp translation_content(_project_id, %{"content" => content}) when is_binary(content),
    do: content

  defp translation_content(project_id, %{"status" => "published", "file_path" => file_path})
       when is_binary(file_path) and file_path != "" do
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

  defp build_match_query(query, language) do
    query
    |> query_variants(language)
    |> Enum.map_join(" OR ", fn tokens ->
      tokens
      |> Enum.map_join(" AND ", &quoted_term/1)
      |> then(&("(" <> &1 <> ")"))
    end)
  end

  defp query_variants(query, language) do
    languages = query_languages(query, language)
    tokens = tokenize_text(query)

    languages
    |> Enum.map(fn stemmer_language -> Enum.map(tokens, &stem_token(&1, stemmer_language)) end)
    |> Enum.reject(&Enum.empty?/1)
    |> Enum.uniq()
  end

  defp query_languages(query, nil) do
    detected = detect_language(query)

    ([detected] ++ list_stemmer_languages())
    |> Enum.uniq()
  end

  defp query_languages(_query, language), do: [normalize_language(language)]

  defp quoted_term(term), do: ~s("#{String.replace(term, ~s("), ~s(\"))}")

  defp tokenize_text(nil), do: []

  defp tokenize_text(text) do
    Regex.scan(~r/[[:alnum:]]+/u, to_string(text))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
  end

  defp stem_token(token, language) do
    case Map.fetch(@stemmer_algorithms, normalize_language(language)) do
      {:ok, algorithm} -> apply(Stemex, algorithm, [token])
      :error -> token
    end
  rescue
    _error -> token
  end

  defp normalize_language(nil), do: "en"

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
    |> then(fn code -> if code in @stemmer_languages, do: code, else: "en" end)
  end

  defp detect_language_from_hints(text) do
    tokens = MapSet.new(tokenize_text(text))

    Enum.find_value(@language_hints, "en", fn {language, hints} ->
      if Enum.any?(hints, &MapSet.member?(tokens, &1)), do: language, else: false
    end)
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

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default), do: normalize_integer(value) || default

  defp normalize_timestamp(nil, _position), do: nil

  defp normalize_timestamp(value, _position) when is_integer(value),
    do: Persistence.normalize_unix_timestamp(value)

  defp normalize_timestamp(value, position) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        time = if position == :start, do: ~T[00:00:00], else: ~T[23:59:59]
        {:ok, datetime} = DateTime.new(date, time, "Etc/UTC")
        DateTime.to_unix(datetime, :millisecond)

      {:error, _reason} ->
        nil
    end
  end

  defp blank_query?(query), do: query in [nil, ""] or String.trim(to_string(query)) == ""
end
