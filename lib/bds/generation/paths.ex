defmodule BDS.Generation.Paths do
  @moduledoc false

  alias BDS.Persistence

  @typedoc "A language identifier (e.g. `\"en\"`) or `nil`/`\"\"` for the main language."
  @type language :: String.t() | nil

  @doc "Output path for a published post (e.g. `2024/05/12/slug/index.html`)."
  @spec post_output_path(map()) :: String.t()
  def post_output_path(post), do: post_output_path(post, nil)

  @spec post_output_path(map(), language()) :: String.t()
  def post_output_path(post, language) when is_map(post) do
    {year, month, day} = local_date_parts!(post.created_at)
    year = Integer.to_string(year)
    month = month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = day |> Integer.to_string() |> String.pad_leading(2, "0")

    language
    |> maybe_prepend_language([year, month, day, post.slug, "index.html"])
    |> Path.join()
  end

  @spec paginated_archive_paths(language(), [String.t()], non_neg_integer(), pos_integer()) ::
          [String.t()]
  def paginated_archive_paths(route_language, segments, total_items, max_posts_per_page) do
    total_pages = page_count(total_items, max_posts_per_page)

    Enum.map(1..total_pages, fn page_number ->
      archive_path(route_language, segments, page_number)
    end)
  end

  @spec root_route_paths(language(), non_neg_integer(), pos_integer()) :: [String.t()]
  def root_route_paths(route_language, total_items, max_posts_per_page) do
    total_pages = page_count(total_items, max_posts_per_page)

    Enum.map(1..total_pages, fn page_number ->
      root_output_path(route_language, page_number)
    end)
  end

  @spec root_output_path(language(), pos_integer()) :: String.t()
  def root_output_path(route_language, page_number),
    do:
      route_language
      |> maybe_prepend_language(root_output_path_segments(page_number))
      |> Path.join()

  @spec page_output_path(String.t(), language()) :: String.t()
  def page_output_path(slug, language),
    do: language |> maybe_prepend_language([slug, "index.html"]) |> Path.join()

  @spec pagination_for_page(
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          language(),
          [String.t()]
        ) ::
          map()
  def pagination_for_page(
        page_number,
        total_pages,
        total_items,
        items_per_page,
        route_language,
        segments
      ) do
    %{
      current_page: page_number,
      total_pages: total_pages,
      total_items: total_items,
      items_per_page: items_per_page,
      has_prev_page: page_number > 1,
      prev_page_href: archive_or_root_href(route_language, segments, page_number - 1),
      has_next_page: page_number < total_pages,
      next_page_href: archive_or_root_href(route_language, segments, page_number + 1)
    }
  end

  @spec archive_or_root_href(language(), [String.t()], integer()) :: String.t()
  def archive_or_root_href(_route_language, _segments, page_number) when page_number < 1, do: ""

  def archive_or_root_href(route_language, [], page_number),
    do: root_page_href(route_language, page_number)

  def archive_or_root_href(route_language, segments, page_number),
    do: archive_href(route_language, segments, page_number)

  @spec root_page_href(language(), integer()) :: String.t()
  def root_page_href(route_language, page_number) when page_number <= 1,
    do: language_route_prefix(route_language) <> "/"

  def root_page_href(route_language, page_number) do
    base = language_route_prefix(route_language)

    "#{base}/page/#{page_number}/"
  end

  @spec archive_href(language(), [String.t()], pos_integer()) :: String.t()
  def archive_href(language, segments, page_number) do
    archive_path(language, segments, page_number)
    |> String.trim_trailing("index.html")
    |> then(&("/" <> String.trim_leading(&1, "/")))
  end

  @spec page_count(integer(), pos_integer()) :: pos_integer()
  def page_count(total_items, _max_posts_per_page) when total_items <= 0, do: 1

  def page_count(total_items, max_posts_per_page) do
    page_size = max(max_posts_per_page, 1)
    div(total_items + page_size - 1, page_size)
  end

  @spec paginate_posts([map()], pos_integer()) :: [[map()]]
  def paginate_posts(posts, max_posts_per_page) do
    case Enum.chunk_every(posts, max(max_posts_per_page, 1)) do
      [] -> [[]]
      chunks -> chunks
    end
  end

  @spec root_pagination_pages(non_neg_integer(), pos_integer()) :: [pos_integer()]
  def root_pagination_pages(total_items, max_posts_per_page) do
    case page_count(total_items, max_posts_per_page) do
      total_pages when total_pages > 1 -> Enum.to_list(2..total_pages)
      _other -> []
    end
  end

  @spec archive_path(language(), [String.t()], pos_integer()) :: String.t()
  def archive_path(language, segments, 1), do: archive_path(language, segments)

  def archive_path(language, segments, page_number) do
    archive_path(language, segments ++ ["page", Integer.to_string(page_number)])
  end

  @spec archive_path(language(), [String.t()]) :: String.t()
  def archive_path(language, segments),
    do: language |> maybe_prepend_language(segments ++ ["index.html"]) |> Path.join()

  @spec archive_route_segment(any()) :: String.t()
  def archive_route_segment(nil), do: ""

  def archive_route_segment(value),
    do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  @spec normalize_base_url(String.t() | nil) :: String.t() | nil
  def normalize_base_url(nil), do: nil
  def normalize_base_url(url), do: String.trim_trailing(url, "/")

  @spec normalize_blog_languages(String.t() | nil, [String.t()] | nil) :: [String.t()]
  def normalize_blog_languages(main_language, blog_languages) do
    ([main_language] ++ (blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  @spec route_language(language(), language()) :: language()
  def route_language(main_language, language) when main_language == language, do: nil
  def route_language(_main_language, language), do: language

  @spec language_prefix(language(), language()) :: String.t()
  def language_prefix(language, main_language) when language == main_language, do: ""
  def language_prefix(nil, _main_language), do: ""
  def language_prefix(language, _main_language), do: "/#{language}"

  @spec url_for_path(String.t() | nil, String.t()) :: String.t()
  def url_for_path(nil, path), do: ensure_trailing_slash(path)

  def url_for_path(base_url, path) do
    String.trim_trailing(base_url, "/") <> ensure_trailing_slash(path)
  end

  @spec url_for_output(String.t() | nil, String.t()) :: String.t()
  def url_for_output(nil, relative_path), do: "/" <> String.trim_leading(relative_path, "/")

  def url_for_output(base_url, relative_path) do
    cleaned = relative_path |> String.trim_leading("/") |> String.trim_trailing("index.html")
    suffix = if cleaned == "", do: "/", else: "/" <> cleaned
    String.trim_trailing(base_url, "/") <> suffix
  end

  @spec ensure_trailing_slash(String.t()) :: String.t()
  def ensure_trailing_slash(path) do
    normalized_path = normalize_url_path(path)
    if normalized_path == "/", do: "/", else: normalized_path <> "/"
  end

  @spec normalize_url_path(String.t() | nil) :: String.t()
  def normalize_url_path(nil), do: "/"

  def normalize_url_path(url_path) do
    trimmed = String.trim(url_path || "")

    cond do
      trimmed in ["", "/"] ->
        "/"

      true ->
        trimmed
        |> String.split(["?", "#"])
        |> List.first()
        |> to_string()
        |> String.trim("/")
        |> case do
          "" -> "/"
          value -> "/" <> value
        end
    end
  end

  @spec relative_path_to_url_path(String.t()) :: String.t()
  def relative_path_to_url_path(relative_path) do
    relative_path
    |> String.trim_leading("/")
    |> String.trim_trailing("index.html")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      value -> "/" <> value
    end
  end

  @spec url_path_to_relative_index_path(String.t()) :: String.t()
  def url_path_to_relative_index_path("/"), do: "index.html"

  def url_path_to_relative_index_path(url_path) do
    url_path
    |> normalize_url_path()
    |> String.trim_leading("/")
    |> Path.join("index.html")
  end

  @spec sitemap_route_output?(String.t()) :: boolean()
  def sitemap_route_output?("404.html"), do: false
  def sitemap_route_output?("feed.xml"), do: false
  def sitemap_route_output?("atom.xml"), do: false
  def sitemap_route_output?("calendar.json"), do: false
  def sitemap_route_output?(relative_path), do: String.ends_with?(relative_path, ".html")

  @spec truthy_flag?(term()) :: boolean()
  def truthy_flag?(value), do: value not in [false, nil]

  defp root_output_path_segments(1), do: ["index.html"]
  defp root_output_path_segments(page_number), do: ["page", Integer.to_string(page_number), "index.html"]

  defp maybe_prepend_language(language, segments) when language in [nil, ""], do: segments
  defp maybe_prepend_language(language, segments), do: [language | segments]

  defp language_route_prefix(language) when language in [nil, ""], do: ""
  defp language_route_prefix(language), do: "/#{language}"

  @doc "Returns the local-time `{year, month, day}` for a unix-ms-or-binary timestamp."
  @spec local_date_parts!(term()) :: {integer(), integer(), integer()}
  def local_date_parts!(value) do
    normalized = Persistence.normalize_unix_timestamp(value)
    {{year, month, day}, _time} = :calendar.system_time_to_local_time(normalized, :millisecond)
    {year, month, day}
  end

  @spec local_date_iso8601!(term()) :: String.t()
  def local_date_iso8601!(value) do
    {year, month, day} = local_date_parts!(value)
    Date.new!(year, month, day) |> Date.to_iso8601()
  end
end
