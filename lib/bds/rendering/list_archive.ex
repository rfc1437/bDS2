defmodule BDS.Rendering.ListArchive do
  @moduledoc false

  alias BDS.MapUtils
  alias BDS.Persistence
  alias BDS.Rendering.Labels
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata, as: RenderMetadata
  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.TemplateSelection
  use Gettext, backend: BDS.Gettext

  @spec list_assigns(String.t(), map()) :: map()
  def list_assigns(project_id, assigns) do
    metadata = RenderMetadata.project_metadata(project_id)
    template_context = TemplateSelection.template_render_context(project_id)

    language = MapUtils.attr(assigns, :language, metadata.main_language || "en")

    main_language = metadata.main_language || language
    archive_context = MapUtils.attr(assigns, :archive_context, %{})

    canonical_post_paths =
      LinksAndLanguages.canonical_post_path_by_slug(project_id, main_language)

    canonical_media_paths = LinksAndLanguages.canonical_media_path_by_source_path(project_id)

    input_posts = MapUtils.attr(assigns, :posts, [])

    post_ids =
      input_posts
      |> Enum.map(&MapUtils.attr(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    post_records = PostRendering.load_post_records_batch(post_ids)

    posts =
      normalize_list_posts(
        input_posts,
        post_records,
        canonical_post_paths,
        canonical_media_paths,
        language,
        template_context
      )

    pagination =
      normalize_pagination(MapUtils.attr(assigns, :pagination), posts)

    day_blocks = build_day_blocks(posts)
    min_date = min_date(posts)
    max_date = max_date(posts)
    normalized_archive_context = normalize_archive_context(archive_context)

    %{
      language: language,
      language_prefix:
        Map.get(
          assigns,
          :language_prefix,
          Map.get(
            assigns,
            "language_prefix",
            LinksAndLanguages.language_prefix(language, main_language)
          )
        ),
      page_title: MapUtils.attr(assigns, :page_title),
      posts: posts,
      pico_stylesheet_href:
        Map.get(
          assigns,
          :pico_stylesheet_href,
          Map.get(
            assigns,
            "pico_stylesheet_href",
            RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
          )
        ),
      html_theme_attribute:
        Map.get(
          assigns,
          :html_theme_attribute,
          Map.get(assigns, "html_theme_attribute")
        ),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      alternate_links: [],
      menu_items: RenderMetadata.menu_items(project_id),
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
      canonical_post_path_by_slug: canonical_post_paths,
      canonical_media_path_by_source_path: canonical_media_paths,
      post_data_json_by_id:
        Enum.into(posts, %{}, fn post -> {post.id, PostRendering.post_data_json_value(post)} end),
      day_blocks: day_blocks,
      archive_month_name:
        Labels.month_name(Map.get(normalized_archive_context, :month), language),
      labels: Labels.for_language(language)
    }
  end

  @spec not_found_assigns(String.t(), map()) :: map()
  def not_found_assigns(project_id, assigns) do
    metadata = RenderMetadata.project_metadata(project_id)

    language = MapUtils.attr(assigns, :language, metadata.main_language || "en")

    main_language = metadata.main_language || language

    %{
      page_title: MapUtils.attr(assigns, :page_title, "404"),
      language: language,
      language_prefix:
        Map.get(
          assigns,
          :language_prefix,
          Map.get(
            assigns,
            "language_prefix",
            LinksAndLanguages.language_prefix(language, main_language)
          )
        ),
      pico_stylesheet_href:
        Map.get(
          assigns,
          :pico_stylesheet_href,
          Map.get(
            assigns,
            "pico_stylesheet_href",
            RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
          )
        ),
      html_theme_attribute:
        Map.get(
          assigns,
          :html_theme_attribute,
          Map.get(assigns, "html_theme_attribute")
        ),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      menu_items: RenderMetadata.menu_items(project_id),
      alternate_links: [],
      not_found_message:
        Map.get(
          assigns,
          :not_found_message,
          Map.get(
            assigns,
            "not_found_message",
            BDS.Gettext.lgettext(
              language,
              "render",
              "The requested preview page could not be found."
            )
          )
        ),
      not_found_back_label:
        Map.get(
          assigns,
          :not_found_back_label,
          Map.get(
            assigns,
            "not_found_back_label",
            BDS.Gettext.lgettext(language, "render", "Back to preview home")
          )
        ),
      labels: Labels.for_language(language)
    }
  end

  defp normalize_list_posts(
         posts,
         post_records,
         canonical_post_paths,
         canonical_media_paths,
         language,
         template_context
       ) do
    Enum.map(posts, fn post ->
      post_id = MapUtils.attr(post, :id)
      post_record = Map.get(post_records, post_id)

      raw_content =
        Map.get(
          post,
          :content,
          MapUtils.attr(post, :excerpt, "")
        )

      %{
        id: MapUtils.attr(post, :id),
        slug: MapUtils.attr(post, :slug),
        title: MapUtils.attr(post, :title),
        content:
          PostRendering.render_post_content(
            raw_content,
            canonical_post_paths,
            canonical_media_paths,
            language,
            template_context
          ),
        raw_content: raw_content,
        excerpt: MapUtils.attr(post, :excerpt, Map.get(post_record || %{}, :excerpt)),
        author: MapUtils.attr(post, :author, Map.get(post_record || %{}, :author)),
        language:
          Map.get(
            post,
            :language,
            Map.get(post_record || %{}, :language)
          ),
        published_at:
          MapUtils.attr(post, :published_at, Map.get(post_record || %{}, :published_at)),
        created_at: MapUtils.attr(post, :created_at, Map.get(post_record || %{}, :created_at)),
        updated_at: MapUtils.attr(post, :updated_at, Map.get(post_record || %{}, :updated_at)),
        tags: MapUtils.attr(post, :tags, Map.get(post_record || %{}, :tags, [])) || [],
        categories:
          MapUtils.attr(post, :categories, Map.get(post_record || %{}, :categories, [])) || [],
        template_slug:
          MapUtils.attr(post, :template_slug, Map.get(post_record || %{}, :template_slug)),
        do_not_translate:
          MapUtils.attr(
            post,
            :do_not_translate,
            Map.get(post_record || %{}, :do_not_translate, false)
          ),
        href: MapUtils.attr(post, :href),
        show_title: true,
        linked_media: [],
        outgoing_links: [],
        incoming_links: []
      }
    end)
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

end
