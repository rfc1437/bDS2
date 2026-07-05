defmodule BDS.Generation.Sitemap do
  @moduledoc false

  alias BDS.Generation.Paths
  alias BDS.Persistence

  @doc "Render a simple sitemap with a flat list of URLs."
  @spec render([String.t()]) :: String.t()
  def render(urls) do
    entries = Enum.map_join(urls, "", fn url -> "<url><loc>#{xml_escape(url)}</loc></url>" end)
    "<urlset>#{entries}</urlset>"
  end

  @doc "Render the multilingual sitemap with hreflang alternates for the project."
  @spec render_multi_language(map(), [map()], [map()], [map()], map(), [String.t()]) :: String.t()
  def render_multi_language(
        plan,
        translatable_posts,
        do_not_translate_posts,
        published_list_posts,
        post_index,
        additional_languages
      ) do
    all_languages = [plan.language | additional_languages]
    latest_post_updated_at = latest_post_updated_at_iso(published_list_posts)

    urls =
      [
        build_url_entry(
          plan.base_url,
          "/",
          latest_post_updated_at,
          "daily",
          "1.0",
          plan.language,
          all_languages
        )
      ] ++
        Enum.map(
          Paths.root_pagination_pages(length(published_list_posts), plan.max_posts_per_page),
          fn page_number ->
            page_path = "/page/#{page_number}"

            build_url_entry(
              plan.base_url,
              page_path,
              latest_post_updated_at,
              "daily",
              "0.9",
              plan.language,
              all_languages
            )
          end
        ) ++
        Enum.map(translatable_posts, fn post ->
          post_path = Paths.relative_path_to_url_path(Paths.post_output_path(post))

          build_url_entry(
            plan.base_url,
            post_path,
            unix_ms_to_iso8601(post.updated_at),
            "monthly",
            "0.8",
            plan.language,
            all_languages
          )
        end) ++
        Enum.map(do_not_translate_posts, fn post ->
          post_path = Paths.relative_path_to_url_path(Paths.post_output_path(post))

          build_url_entry(
            plan.base_url,
            post_path,
            unix_ms_to_iso8601(post.updated_at),
            "monthly",
            "0.8",
            plan.language,
            [plan.language]
          )
        end) ++
        Enum.flat_map(translatable_posts ++ do_not_translate_posts, fn post ->
          if "page" in (post.categories || []) and to_string(post.slug) != "" do
            page_path = Paths.relative_path_to_url_path(Paths.page_output_path(post.slug, nil))

            languages =
              if Paths.truthy_flag?(post.do_not_translate),
                do: [plan.language],
                else: all_languages

            [
              build_url_entry(
                plan.base_url,
                page_path,
                unix_ms_to_iso8601(post.updated_at),
                "weekly",
                "0.7",
                plan.language,
                languages
              )
            ]
          else
            []
          end
        end) ++
        Enum.map(Enum.sort_by(post_index.posts_by_year, &elem(&1, 0), :desc), fn {year, _posts} ->
          year_path = "/#{year}"

          build_url_entry(
            plan.base_url,
            year_path,
            latest_post_updated_at,
            "monthly",
            "0.5",
            plan.language,
            all_languages
          )
        end) ++
        Enum.map(
          Enum.sort_by(post_index.posts_by_year_month, &elem(&1, 0), :desc),
          fn {year_month, _posts} ->
            month_path = "/#{year_month}"

            build_url_entry(
              plan.base_url,
              month_path,
              latest_post_updated_at,
              "monthly",
              "0.5",
              plan.language,
              all_languages
            )
          end
        ) ++
        Enum.map(
          Enum.sort_by(post_index.posts_by_year_month_day, &elem(&1, 0), :desc),
          fn {year_month_day, _posts} ->
            day_path = "/#{year_month_day}"

            build_url_entry(
              plan.base_url,
              day_path,
              latest_post_updated_at,
              "monthly",
              "0.4",
              plan.language,
              all_languages
            )
          end
        ) ++
        Enum.map(Enum.sort_by(post_index.posts_by_category, &elem(&1, 0)), fn {category, _posts} ->
          category_path = "/category/#{Paths.archive_route_segment(category)}"

          build_url_entry(
            plan.base_url,
            category_path,
            latest_post_updated_at,
            "weekly",
            "0.6",
            plan.language,
            all_languages
          )
        end) ++
        Enum.map(Enum.sort_by(post_index.posts_by_tag, &elem(&1, 0)), fn {tag, _posts} ->
          tag_path = "/tag/#{Paths.archive_route_segment(tag)}"

          build_url_entry(
            plan.base_url,
            tag_path,
            latest_post_updated_at,
            "weekly",
            "0.6",
            plan.language,
            all_languages
          )
        end)

    [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">",
      Enum.join(urls, "\n"),
      "</urlset>",
      ""
    ]
    |> Enum.join("\n")
  end

  @doc "Render an RSS feed for the given language."
  @spec render_feed(map(), String.t() | nil, [map()]) :: String.t()
  def render_feed(plan, language, published_posts) do
    items =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<item><title>#{xml_escape(post.title)}</title><link>#{Paths.url_for_output(plan.base_url, Paths.post_output_path(post))}</link></item>"
      end)
      |> Enum.join()

    "<rss><channel><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{items}</channel></rss>"
  end

  @doc "Render an Atom feed for the given language."
  @spec render_atom(map(), String.t() | nil, [map()]) :: String.t()
  def render_atom(plan, language, published_posts) do
    entries =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<entry><title>#{xml_escape(post.title)}</title><id>#{Paths.url_for_output(plan.base_url, Paths.post_output_path(post))}</id></entry>"
      end)
      |> Enum.join()

    "<feed><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{entries}</feed>"
  end

  @doc """
  Render the JSON calendar archive consumed by the calendar runtime:
  post counts keyed by year ("2024"), month ("2024-05"), and day ("2024-05-17").
  """
  @spec render_calendar([map()]) :: String.t()
  def render_calendar(published_posts) do
    day_keys = Enum.map(published_posts, &Paths.local_date_iso8601!(&1.created_at))

    %{
      years: Enum.frequencies_by(day_keys, &binary_part(&1, 0, 4)),
      months: Enum.frequencies_by(day_keys, &binary_part(&1, 0, 7)),
      days: Enum.frequencies(day_keys)
    }
    |> Jason.encode!()
  end

  @doc "Extract the `<loc>` values from a sitemap XML document."
  @spec extract_locs(String.t()) :: [String.t()]
  def extract_locs(sitemap_xml) do
    Regex.scan(~r/<loc>(.*?)<\/loc>/, sitemap_xml, capture: :all_but_first)
    |> Enum.map(fn [value] -> String.trim(value) end)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Translate a sitemap `<loc>` URL to a normalized project-relative URL path."
  @spec loc_to_project_path(String.t(), String.t() | nil) :: String.t()
  def loc_to_project_path(loc, nil), do: Paths.normalize_url_path(loc)

  def loc_to_project_path(loc, base_url) do
    with {:ok, loc_uri} <- URI.new(loc),
         {:ok, base_uri} <- URI.new(base_url) do
      loc_path = String.trim_trailing(loc_uri.path || "/", "/")
      base_path = String.trim_trailing(base_uri.path || "", "/")

      cond do
        base_path != "" and String.starts_with?(loc_path, base_path) ->
          loc_path
          |> String.replace_prefix(base_path, "")
          |> Paths.normalize_url_path()

        true ->
          Paths.normalize_url_path(loc_path)
      end
    else
      _other -> Paths.normalize_url_path(loc)
    end
  end

  @doc "Escape a string for inclusion in XML."
  @spec xml_escape(term()) :: String.t()
  def xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc "ISO-8601 string of the most recently updated post (or now)."
  @spec latest_post_updated_at_iso([map()]) :: String.t()
  def latest_post_updated_at_iso([]), do: DateTime.utc_now() |> DateTime.to_iso8601()
  def latest_post_updated_at_iso([post | _rest]), do: unix_ms_to_iso8601(post.updated_at)

  @doc "Convert a unix-ms (or nil) timestamp to ISO-8601."
  @spec unix_ms_to_iso8601(integer() | nil) :: String.t()
  def unix_ms_to_iso8601(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  def unix_ms_to_iso8601(value), do: value |> Persistence.from_unix_ms!() |> DateTime.to_iso8601()

  defp build_hreflang_links(base_url, url_path, main_language, languages) do
    Enum.map(languages, fn language ->
      prefixed_path =
        if language == main_language do
          url_path
        else
          Paths.normalize_url_path("/#{language}#{url_path}")
        end

      canonical_href = Paths.url_for_path(base_url, prefixed_path)

      "    <xhtml:link rel=\"alternate\" hreflang=\"#{xml_escape(language)}\" href=\"#{xml_escape(canonical_href)}\" />"
    end) ++
      [
        "    <xhtml:link rel=\"alternate\" hreflang=\"x-default\" href=\"#{xml_escape(Paths.url_for_path(base_url, url_path))}\" />"
      ]
  end

  defp build_url_entry(base_url, url_path, lastmod, changefreq, priority, main_language, languages) do
    url_entry(
      Paths.url_for_path(base_url, url_path),
      lastmod,
      changefreq,
      priority,
      build_hreflang_links(base_url, url_path, main_language, languages)
    )
  end

  defp url_entry(loc, lastmod, changefreq, priority, hreflang_links) do
    [
      "  <url>",
      "    <loc>#{xml_escape(loc)}</loc>",
      "    <lastmod>#{xml_escape(lastmod)}</lastmod>",
      "    <changefreq>#{changefreq}</changefreq>",
      "    <priority>#{priority}</priority>",
      Enum.join(hreflang_links, "\n"),
      "  </url>"
    ]
    |> Enum.join("\n")
  end
end
