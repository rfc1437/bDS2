defmodule BDS.Rendering.ListArchive do
  @moduledoc false

  alias BDS.MapUtils
  alias BDS.Persistence
  alias BDS.Rendering.Labels
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata, as: RenderMetadata
  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.RenderContext
  use Gettext, backend: BDS.Gettext

  @spec list_assigns(RenderContext.t() | String.t(), map()) :: map()
  def list_assigns(project_id, assigns) when is_binary(project_id) do
    list_assigns(RenderContext.build(project_id), assigns)
  end

  def list_assigns(%RenderContext{} = ctx, assigns) do
    metadata = ctx.metadata

    language = MapUtils.attr(assigns, :language, metadata.main_language || "en")

    main_language = metadata.main_language || language
    archive_context = MapUtils.attr(assigns, :archive_context, %{})

    input_posts = MapUtils.attr(assigns, :posts, [])

    posts = normalize_list_posts(ctx, input_posts, language)

    pagination =
      normalize_pagination(MapUtils.attr(assigns, :pagination), posts)

    day_blocks = build_day_blocks(posts)
    min_date = min_date(posts)
    max_date = max_date(posts)
    normalized_archive_context = normalize_archive_context(archive_context)

    %{
      language: language,
      language_prefix: assign_override(
        assigns,
        :language_prefix,
        "language_prefix",
        LinksAndLanguages.language_prefix(language, main_language)
      ),
      page_title: MapUtils.attr(assigns, :page_title),
      posts: posts,
      pico_stylesheet_href: assign_override(
        assigns,
        :pico_stylesheet_href,
        "pico_stylesheet_href",
        RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
      ),
      html_theme_attribute:
        assign_override(assigns, :html_theme_attribute, "html_theme_attribute", nil),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      alternate_links: [],
      menu_items: ctx.menu_items,
      calendar_initial_year: calendar_initial_year_from_posts(posts),
      calendar_initial_month: calendar_initial_month_from_posts(posts),
      archive_context: normalized_archive_context,
      show_archive_range_heading:
        show_archive_range_heading?(normalized_archive_context, day_blocks),
      min_date: min_date,
      max_date: max_date,
      is_list_page: true,
      is_first_page: pagination.current_page <= 1,
      is_last_page: pagination.current_page >= pagination.total_pages,
      has_prev_page: pagination.has_prev_page,
      has_next_page: pagination.has_next_page,
      prev_page_href: pagination.prev_page_href,
      next_page_href: pagination.next_page_href,
      current_page: pagination.current_page,
      total_pages: pagination.total_pages,
      total_items: pagination.total_items,
      items_per_page: pagination.items_per_page,
      canonical_post_path_by_slug: ctx.canonical_post_paths,
      canonical_media_path_by_source_path: ctx.canonical_media_paths,
      post_data_json_by_id:
        Enum.into(posts, %{}, fn post -> {post.id, PostRendering.post_data_json_value(post)} end),
      day_blocks: day_blocks,
      archive_month_name:
        Labels.month_name(Map.get(normalized_archive_context, :month), language),
      labels: Labels.for_language(language)
    }
  end

  @spec not_found_assigns(RenderContext.t() | String.t(), map()) :: map()
  def not_found_assigns(project_id, assigns) when is_binary(project_id) do
    not_found_assigns(RenderContext.build(project_id), assigns)
  end

  def not_found_assigns(%RenderContext{} = ctx, assigns) do
    metadata = ctx.metadata

    language = MapUtils.attr(assigns, :language, metadata.main_language || "en")

    main_language = metadata.main_language || language

    %{
      page_title: MapUtils.attr(assigns, :page_title, "404"),
      language: language,
      language_prefix: assign_override(
        assigns,
        :language_prefix,
        "language_prefix",
        LinksAndLanguages.language_prefix(language, main_language)
      ),
      pico_stylesheet_href: assign_override(
        assigns,
        :pico_stylesheet_href,
        "pico_stylesheet_href",
        RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
      ),
      html_theme_attribute:
        assign_override(assigns, :html_theme_attribute, "html_theme_attribute", nil),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      menu_items: ctx.menu_items,
      alternate_links: [],
      not_found_message:
        assign_override(
          assigns,
          :not_found_message,
          "not_found_message",
          BDS.Gettext.lgettext(language, "render", "The requested preview page could not be found.")
        ),
      not_found_back_label:
        assign_override(
          assigns,
          :not_found_back_label,
          "not_found_back_label",
          BDS.Gettext.lgettext(language, "render", "Back to preview home")
        ),
      labels: Labels.for_language(language)
    }
  end

  defp normalize_list_posts(ctx, posts, language) do
    show_title_by_category = show_title_by_category(ctx.metadata)

    Enum.map(posts, fn post ->
      post_id = MapUtils.attr(post, :id)
      post_record = Map.get(ctx.record_by_id, post_id)

      raw_content =
        Map.get(
          post,
          :content,
          MapUtils.attr(post, :excerpt, "")
        )

      categories =
        MapUtils.attr(post, :categories, record_list(post_record, :categories)) || []

      %{
        id: MapUtils.attr(post, :id),
        slug: MapUtils.attr(post, :slug),
        title: MapUtils.attr(post, :title),
        content: PostRendering.cached_post_content(ctx, raw_content, language),
        raw_content: raw_content,
        excerpt: MapUtils.attr(post, :excerpt, record_value(post_record, :excerpt)),
        author: MapUtils.attr(post, :author, record_value(post_record, :author)),
        language: Map.get(post, :language, record_value(post_record, :language)),
        published_at:
          MapUtils.attr(post, :published_at, record_value(post_record, :published_at)),
        created_at: MapUtils.attr(post, :created_at, record_value(post_record, :created_at)),
        updated_at: MapUtils.attr(post, :updated_at, record_value(post_record, :updated_at)),
        tags: MapUtils.attr(post, :tags, record_list(post_record, :tags)) || [],
        categories: categories,
        template_slug:
          MapUtils.attr(post, :template_slug, record_value(post_record, :template_slug)),
        do_not_translate:
          MapUtils.attr(
            post,
            :do_not_translate,
            record_value(post_record, :do_not_translate, false)
          ),
        href: MapUtils.attr(post, :href),
        show_title: show_list_title?(categories, show_title_by_category),
        linked_media: [],
        outgoing_links: [],
        incoming_links: []
      }
    end)
  end

  # A post's title is hidden in list/archive pages when any of its categories
  # has "show title" turned off. Mirrors the single-post behaviour so that, for
  # example, asides render as body-only entries everywhere.
  defp show_list_title?([], _show_title_by_category), do: true

  defp show_list_title?(categories, show_title_by_category) do
    not Enum.any?(categories, fn category ->
      Map.get(show_title_by_category, category, true) == false
    end)
  end

  @default_show_title_by_category %{
    "article" => true,
    "picture" => true,
    "aside" => false,
    "page" => true
  }

  defp show_title_by_category(metadata) do
    settings = Map.get(metadata, :category_settings, %{}) || %{}

    Enum.reduce(settings, @default_show_title_by_category, fn {category, category_settings}, acc ->
      Map.put(acc, category, category_show_title?(category_settings))
    end)
  end

  defp category_show_title?(settings) do
    case MapUtils.attr(settings, :show_title, true) do
      false -> false
      _other -> true
    end
  end

  defp normalize_pagination(nil, posts) do
    total_items = length(posts)

    %{
      current_page: 1,
      total_pages: 1,
      total_items: total_items,
      items_per_page: total_items,
      has_prev_page: false,
      prev_page_href: "",
      has_next_page: false,
      next_page_href: ""
    }
  end

  defp normalize_pagination(%{} = pagination, posts) do
    total_items =
      MapUtils.attr(pagination, :total_items, length(posts))

    items_per_page =
      MapUtils.attr(pagination, :items_per_page, total_items)

    %{
      current_page: MapUtils.attr(pagination, :current_page, 1),
      total_pages: MapUtils.attr(pagination, :total_pages, 1),
      total_items: total_items,
      items_per_page: items_per_page,
      has_prev_page: MapUtils.attr(pagination, :has_prev_page, false),
      prev_page_href: MapUtils.attr(pagination, :prev_page_href, ""),
      has_next_page: MapUtils.attr(pagination, :has_next_page, false),
      next_page_href: MapUtils.attr(pagination, :next_page_href, "")
    }
  end

  defp normalize_archive_context(nil), do: nil

  defp normalize_archive_context(%{} = archive_context) do
    %{
      kind: MapUtils.attr(archive_context, :kind),
      name: MapUtils.attr(archive_context, :name),
      month: MapUtils.attr(archive_context, :month),
      year: MapUtils.attr(archive_context, :year),
      day: MapUtils.attr(archive_context, :day)
    }
  end

  defp build_day_blocks(posts) do
    grouped_blocks =
      posts
      |> Enum.filter(&is_integer(Map.get(&1, :created_at)))
      |> Enum.group_by(
        &(Map.get(&1, :created_at)
          |> Persistence.from_unix_ms!()
          |> DateTime.to_date()
          |> Date.to_iso8601())
      )
      |> Enum.sort_by(fn {label, _posts} -> label end)

    last_index = length(grouped_blocks) - 1

    grouped_blocks
    |> Enum.with_index()
    |> Enum.map(fn {{date_label, grouped_posts}, index} ->
      %{
        date_label: date_label,
        show_date_marker: true,
        show_separator: index < last_index,
        posts: Enum.sort_by(grouped_posts, &Map.get(&1, :created_at))
      }
    end)
    |> case do
      [] -> [%{date_label: "", show_date_marker: false, show_separator: false, posts: posts}]
      blocks -> blocks
    end
  end

  defp min_date(posts) do
    posts
    |> Enum.map(&Map.get(&1, :created_at))
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp max_date(posts) do
    posts
    |> Enum.map(&Map.get(&1, :created_at))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp show_archive_range_heading?(%{kind: "date"}, _day_blocks), do: true
  defp show_archive_range_heading?(_archive_context, _day_blocks), do: false

  defp calendar_initial_year_from_posts([post | _rest]),
    do: RenderMetadata.calendar_initial_year(post)

  defp calendar_initial_year_from_posts([]), do: nil

  defp calendar_initial_month_from_posts([post | _rest]),
    do: RenderMetadata.calendar_initial_month(post)

  defp calendar_initial_month_from_posts([]), do: nil

  defp assign_override(assigns, atom_key, string_key, default) do
    Map.get(assigns, atom_key, Map.get(assigns, string_key, default))
  end

  defp record_value(post_record, key, default \\ nil) do
    Map.get(post_record || %{}, key, default)
  end

  defp record_list(post_record, key), do: record_value(post_record, key, []) || []
end
