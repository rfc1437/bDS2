defmodule BDS.Rendering do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Menu
  alias BDS.Metadata
  alias BDS.PostLinks
  alias BDS.Projects
  alias BDS.I18n
  alias BDS.Rendering.FileSystem
  alias BDS.Rendering.Filters
  alias BDS.Repo
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  def render_post_page(project_id, template_slug, assigns)
      when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :post, template_slug),
         {:ok, rendered} <-
           render_template(project_id, template_source, post_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_list_page(project_id, assigns) when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :list, nil),
         {:ok, rendered} <-
           render_template(project_id, template_source, list_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_not_found_page(project_id, assigns \\ %{})
      when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :not_found, nil),
         {:ok, rendered} <-
           render_template(project_id, template_source, not_found_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  defp load_template_source(project_id, kind, slug) do
    case select_template(project_id, kind, slug) do
      nil -> {:error, :template_not_found}
      %Template{} = template -> published_template_body(template)
    end
  end

  defp select_template(project_id, kind, slug) when is_binary(slug) and slug != "" do
    Repo.one(
      from template in Template,
        where:
          template.project_id == ^project_id and template.kind == ^kind and
            template.status == :published and
            template.enabled == true and template.slug == ^slug,
        limit: 1
    ) || select_template(project_id, kind, nil)
  end

  defp select_template(project_id, kind, nil) do
    Repo.one(
      from template in Template,
        where:
          template.project_id == ^project_id and template.kind == ^kind and
            template.status == :published and
            template.enabled == true,
        order_by: [asc: template.created_at, asc: template.slug],
        limit: 1
    )
  end

  defp published_template_body(%Template{content: content}) when is_binary(content),
    do: {:ok, content}

  defp published_template_body(%Template{} = template) do
    project = Projects.get_project!(template.project_id)
    full_path = Path.join(Projects.project_data_dir(project), template.file_path)

    case File.read(full_path) do
      {:ok, contents} ->
        case Frontmatter.parse_document(contents) do
          {:ok, %{body: body}} -> {:ok, body}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_template(project_id, source, assigns) do
    with {:ok, template_ast} <- Liquex.parse(source) do
      project = Projects.get_project!(project_id)
      template_root = Path.join(Projects.project_data_dir(project), "templates")

      context =
        Liquex.Context.new(assigns,
          static_environment: assigns,
          filter_module: Filters,
          file_system: FileSystem.new(template_root)
        )

      {result, _context} = Liquex.render!(template_ast, context)
      {:ok, IO.iodata_to_binary(result)}
    end
  rescue
    error -> {:error, error}
  end

  defp post_assigns(project_id, assigns) do
    metadata = project_metadata(project_id)

    language =
      Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))

    main_language = metadata.main_language || language
    post_record = load_post_record(assigns)
    canonical_post = canonical_post_record(post_record)
    post_id = canonical_post_id(post_record, assigns)
    post_categories = Map.get(post_record || %{}, :categories, []) || []
    post_tags = Map.get(post_record || %{}, :tags, []) || []
    canonical_post_paths = canonical_post_path_by_slug(project_id, main_language)
    canonical_media_paths = canonical_media_path_by_source_path(project_id)
    incoming_links = link_contexts(project_id, post_id, :incoming, main_language)
    outgoing_links = link_contexts(project_id, post_id, :outgoing, main_language)

    %{
      language: language,
      language_prefix:
        Map.get(
          assigns,
          :language_prefix,
          Map.get(assigns, "language_prefix", language_prefix(language, main_language))
        ),
      page_title:
        Map.get(
          assigns,
          :page_title,
          Map.get(assigns, "page_title", Map.get(assigns, :title, Map.get(assigns, "title")))
        ),
      pico_stylesheet_href: default_pico_stylesheet_href(),
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      alternate_links: alternate_links(canonical_post, project_id, main_language),
      menu_items: menu_items(project_id),
      calendar_initial_year: calendar_initial_year(post_record),
      calendar_initial_month: calendar_initial_month(post_record),
      post_categories: post_categories,
      post_tags: post_tags,
      tag_color_by_name: tag_color_by_name(project_id),
      backlinks: backlinks(incoming_links),
      canonical_post_path_by_slug: canonical_post_paths,
      canonical_media_path_by_source_path: canonical_media_paths,
      post_data_json_by_id: post_data_json(assigns, post_record),
      post: build_post_context(assigns, post_record, incoming_links, outgoing_links)
    }
  end

  defp list_assigns(project_id, assigns) do
    metadata = project_metadata(project_id)

    language =
      Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))

    main_language = metadata.main_language || language
    posts = normalize_list_posts(Map.get(assigns, :posts, Map.get(assigns, "posts", [])))
    archive_context = Map.get(assigns, :archive_context, Map.get(assigns, "archive_context", %{}))

    pagination =
      normalize_pagination(Map.get(assigns, :pagination, Map.get(assigns, "pagination")), posts)

    canonical_post_paths = canonical_post_path_by_slug(project_id, main_language)
    canonical_media_paths = canonical_media_path_by_source_path(project_id)
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
          Map.get(assigns, "language_prefix", language_prefix(language, main_language))
        ),
      page_title: Map.get(assigns, :page_title, Map.get(assigns, "page_title")),
      posts: posts,
      pico_stylesheet_href: default_pico_stylesheet_href(),
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      alternate_links: [],
      menu_items: menu_items(project_id),
      calendar_initial_year: calendar_initial_year_from_posts(posts),
      calendar_initial_month: calendar_initial_month_from_posts(posts),
      archive_context: normalized_archive_context,
      show_archive_range_heading: show_archive_range_heading?(normalized_archive_context, day_blocks),
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
        Enum.into(posts, %{}, fn post -> {post.id, post_data_json_value(post)} end),
      day_blocks: day_blocks
    }
  end

  defp not_found_assigns(project_id, assigns) do
    metadata = project_metadata(project_id)

    language =
      Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))

    main_language = metadata.main_language || language

    %{
      page_title: Map.get(assigns, :page_title, Map.get(assigns, "page_title", "404")),
      language: language,
      language_prefix:
        Map.get(
          assigns,
          :language_prefix,
          Map.get(assigns, "language_prefix", language_prefix(language, main_language))
        ),
      pico_stylesheet_href: default_pico_stylesheet_href(),
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      menu_items: menu_items(project_id),
      alternate_links: [],
      not_found_message:
        Map.get(
          assigns,
          :not_found_message,
          Map.get(
            assigns,
            "not_found_message",
            I18n.translate(language, "render.notFound.message")
          )
        ),
      not_found_back_label:
        Map.get(
          assigns,
          :not_found_back_label,
          Map.get(
            assigns,
            "not_found_back_label",
            I18n.translate(language, "render.notFound.back")
          )
        )
    }
  end

  defp project_metadata(project_id) do
    case Metadata.get_project_metadata(project_id) do
      {:ok, metadata} -> metadata
      _other -> %{main_language: "en", blog_languages: [], pico_theme: nil}
    end
  end

  defp menu_items(project_id) do
    case Menu.get_menu(project_id) do
      {:ok, %{items: items}} -> Enum.map(items, &to_template_menu_item/1)
      _other -> []
    end
  end

  defp to_template_menu_item(item) do
    kind = Map.get(item, :kind)
    children = Enum.map(Map.get(item, :children, []), &to_template_menu_item/1)

    %{
      title: Map.get(item, :label, ""),
      href: menu_item_href(item),
      has_children: children != [],
      children: children,
      kind: kind
    }
  end

  defp menu_item_href(%{kind: :home}), do: "/"

  defp menu_item_href(%{kind: :page, slug: slug}) when is_binary(slug) and slug != "",
    do: "/#{slug}/"

  defp menu_item_href(%{kind: :category_archive, slug: slug}) when is_binary(slug) and slug != "",
    do: "/category/#{URI.encode(slug)}/"

  defp menu_item_href(%{kind: :submenu}), do: "#"
  defp menu_item_href(_item), do: "#"

  defp blog_languages(metadata, current_language) do
    ([metadata.main_language] ++ (metadata.blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.map(fn language ->
      normalized = I18n.normalize_language(language)
      href_prefix = language_prefix(normalized, metadata.main_language || current_language)

      %{
        code: normalized,
        flag: I18n.flag(normalized),
        href: href_for_language(href_prefix),
        href_prefix: href_prefix,
        is_current: normalized == I18n.normalize_language(current_language)
      }
    end)
  end

  defp tag_color_by_name(project_id) do
    Repo.all(from tag in Tag, where: tag.project_id == ^project_id, select: {tag.name, tag.color})
    |> Enum.into(%{}, fn {name, color} -> {name, color} end)
  end

  defp load_post_record(assigns) do
    case Map.get(assigns, :id, Map.get(assigns, "id")) do
      nil -> nil
      post_id -> Repo.get(Post, post_id) || Repo.get(Translation, post_id)
    end
  end

  defp canonical_post_record(%Translation{translation_for: post_id}), do: Repo.get(Post, post_id)
  defp canonical_post_record(%Post{} = post), do: post
  defp canonical_post_record(_other), do: nil

  defp canonical_post_id(%Translation{translation_for: post_id}, _assigns), do: post_id
  defp canonical_post_id(%Post{id: post_id}, _assigns), do: post_id
  defp canonical_post_id(_post_record, assigns), do: Map.get(assigns, :id, Map.get(assigns, "id"))

  defp post_data_json(assigns, post_record) do
    id = Map.get(assigns, :id, Map.get(assigns, "id"))

    if is_binary(id) do
      incoming_links = link_contexts(Map.get(post_record || %{}, :project_id), canonical_post_id(post_record, assigns), :incoming, Map.get(post_record || %{}, :language))
      outgoing_links = link_contexts(Map.get(post_record || %{}, :project_id), canonical_post_id(post_record, assigns), :outgoing, Map.get(post_record || %{}, :language))

      %{
        id => post_data_json_value(build_post_context(assigns, post_record, incoming_links, outgoing_links))
      }
    else
      %{}
    end
  end

  defp post_data_json_value(post_context) do
    Jason.encode!(%{
      id: Map.get(post_context, :id),
      title: Map.get(post_context, :title),
      slug: Map.get(post_context, :slug),
      excerpt: Map.get(post_context, :excerpt),
      author: Map.get(post_context, :author),
      language: Map.get(post_context, :language),
      published_at: Map.get(post_context, :published_at),
      created_at: Map.get(post_context, :created_at),
      updated_at: Map.get(post_context, :updated_at),
      tags: Map.get(post_context, :tags, []),
      categories: Map.get(post_context, :categories, [])
    })
  end

  defp canonical_post_path_by_slug(project_id, main_language) do
    posts =
      Repo.all(
        from post in Post, where: post.project_id == ^project_id and post.status == :published
      )

    translations =
      Repo.all(
        from translation in Translation,
          where: translation.project_id == ^project_id and translation.status == :published
      )

    post_by_id = Map.new(posts, fn post -> {post.id, post} end)

    post_paths =
      Enum.into(posts, %{}, fn post ->
        {post.slug, post_path(post, nil)}
      end)

    Enum.reduce(translations, post_paths, fn translation, acc ->
      case Map.get(post_by_id, translation.translation_for) do
        nil -> acc
        post -> Map.put(acc, post.slug, post_path(post, translation.language, main_language))
      end
    end)
  end

  defp alternate_links(nil, _project_id, _main_language), do: []

  defp alternate_links(%Post{} = post, project_id, main_language) do
    translations =
      Repo.all(
        from translation in Translation,
          where:
            translation.project_id == ^project_id and
              translation.translation_for == ^post.id and
              translation.status == :published,
          order_by: [asc: translation.language]
      )

    [%{href: post_path(post, nil), hreflang: normalize_language(post.language, main_language)}] ++
      Enum.map(translations, fn translation ->
        %{href: post_path(post, translation.language, main_language), hreflang: translation.language}
      end)
  end

  defp backlinks(incoming_links) do
    Enum.map(incoming_links, fn link ->
      %{path: link.href, display_slug: link.display_slug, title: link.title}
    end)
  end

  defp link_contexts(_project_id, nil, _direction, _main_language), do: []

  defp link_contexts(project_id, post_id, :incoming, main_language) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&link_context(project_id, &1, :incoming, main_language))
    |> Enum.reject(&is_nil/1)
  end

  defp link_contexts(project_id, post_id, :outgoing, main_language) do
    PostLinks.list_outgoing_links(post_id)
    |> Enum.map(&link_context(project_id, &1, :outgoing, main_language))
    |> Enum.reject(&is_nil/1)
  end

  defp link_context(_project_id, link, direction, main_language) do
    linked_post_id =
      case direction do
        :incoming -> link.source_post_id
        :outgoing -> link.target_post_id
      end

    case Repo.get(Post, linked_post_id) do
      nil -> nil
      linked_post -> %{href: post_path(linked_post, nil), title: linked_post.title, display_slug: linked_post.slug, language: normalize_language(linked_post.language, main_language)}
    end
  end

  defp canonical_media_path_by_source_path(project_id) do
    Repo.all(from media in MediaAsset, where: media.project_id == ^project_id)
    |> Enum.reduce(%{}, fn media, acc ->
      datetime = DateTime.from_unix!(media.created_at)

      source_key =
        Path.join([
          "media",
          Integer.to_string(datetime.year),
          String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
          media.original_name
        ])
        |> String.downcase()

      Map.put(acc, source_key, "/" <> media.file_path)
    end)
  end

  defp post_path(post, language_prefix)
       when is_binary(language_prefix) and language_prefix != "" do
    language_prefix <> post_path(post, nil)
  end

  defp post_path(post, nil) do
    datetime = DateTime.from_unix!(post.created_at)

    Path.join([
      Integer.to_string(datetime.year),
      String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
      String.pad_leading(Integer.to_string(datetime.day), 2, "0"),
      post.slug,
      "index.html"
    ])
    |> then(&("/" <> String.trim_trailing(&1, "index.html")))
  end

  defp post_path(post, language, main_language) do
    prefix = language_prefix(language, main_language)
    post_path(post, prefix)
  end

  defp normalize_list_posts(posts) do
    Enum.map(posts, fn post ->
      post_record = load_post_record(post)

      %{
        id: Map.get(post, :id, Map.get(post, "id")),
        slug: Map.get(post, :slug, Map.get(post, "slug")),
        title: Map.get(post, :title, Map.get(post, "title")),
        content:
          Map.get(
            post,
            :content,
            Map.get(post, "content", Map.get(post, :excerpt, Map.get(post, "excerpt", "")))
          ),
        excerpt:
          Map.get(post, :excerpt, Map.get(post, "excerpt", Map.get(post_record || %{}, :excerpt))),
        author: Map.get(post, :author, Map.get(post, "author", Map.get(post_record || %{}, :author))),
        language:
          Map.get(
            post,
            :language,
            Map.get(post, "language", Map.get(post_record || %{}, :language))
          ),
        published_at:
          Map.get(post, :published_at, Map.get(post, "published_at", Map.get(post_record || %{}, :published_at))),
        created_at:
          Map.get(post, :created_at, Map.get(post, "created_at", Map.get(post_record || %{}, :created_at))),
        updated_at:
          Map.get(post, :updated_at, Map.get(post, "updated_at", Map.get(post_record || %{}, :updated_at))),
        tags: Map.get(post, :tags, Map.get(post, "tags", Map.get(post_record || %{}, :tags, []))) || [],
        categories:
          Map.get(post, :categories, Map.get(post, "categories", Map.get(post_record || %{}, :categories, []))) || [],
        template_slug:
          Map.get(post, :template_slug, Map.get(post, "template_slug", Map.get(post_record || %{}, :template_slug))),
        do_not_translate:
          Map.get(post, :do_not_translate, Map.get(post, "do_not_translate", Map.get(post_record || %{}, :do_not_translate, false))),
        href: Map.get(post, :href, Map.get(post, "href")),
        show_title: true,
        linked_media: [],
        outgoing_links: [],
        incoming_links: []
      }
    end)
  end

  defp build_post_context(assigns, post_record, incoming_links, outgoing_links) do
    %{
      id: Map.get(assigns, :id, Map.get(assigns, "id")),
      slug: Map.get(assigns, :slug, Map.get(assigns, "slug")),
      title: Map.get(assigns, :title, Map.get(assigns, "title")),
      content: Map.get(assigns, :content, Map.get(assigns, "content")),
      excerpt:
        Map.get(
          assigns,
          :excerpt,
          Map.get(assigns, "excerpt", Map.get(post_record || %{}, :excerpt))
        ),
      author: Map.get(post_record || %{}, :author),
      language:
        Map.get(
          assigns,
          :language,
          Map.get(assigns, "language", Map.get(post_record || %{}, :language))
        ),
      show_title: true,
      published_at: Map.get(post_record || %{}, :published_at),
      created_at: Map.get(post_record || %{}, :created_at),
      updated_at: Map.get(post_record || %{}, :updated_at),
      tags: Map.get(post_record || %{}, :tags, []) || [],
      categories: Map.get(post_record || %{}, :categories, []) || [],
      template_slug:
        Map.get(
          post_record || %{},
          :template_slug,
          Map.get(assigns, :template_slug, Map.get(assigns, "template_slug"))
        ),
      do_not_translate: Map.get(post_record || %{}, :do_not_translate, false),
      linked_media: [],
      outgoing_links: outgoing_links,
      incoming_links: incoming_links
    }
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
      Map.get(pagination, :total_items, Map.get(pagination, "total_items", length(posts)))

    items_per_page =
      Map.get(pagination, :items_per_page, Map.get(pagination, "items_per_page", total_items))

    %{
      current_page: Map.get(pagination, :current_page, Map.get(pagination, "current_page", 1)),
      total_pages: Map.get(pagination, :total_pages, Map.get(pagination, "total_pages", 1)),
      total_items: total_items,
      items_per_page: items_per_page,
      has_prev_page:
        Map.get(pagination, :has_prev_page, Map.get(pagination, "has_prev_page", false)),
      prev_page_href:
        Map.get(pagination, :prev_page_href, Map.get(pagination, "prev_page_href", "")),
      has_next_page:
        Map.get(pagination, :has_next_page, Map.get(pagination, "has_next_page", false)),
      next_page_href:
        Map.get(pagination, :next_page_href, Map.get(pagination, "next_page_href", ""))
    }
  end

  defp normalize_archive_context(nil), do: nil

  defp normalize_archive_context(%{} = archive_context) do
    %{
      kind: Map.get(archive_context, :kind, Map.get(archive_context, "kind")),
      name: Map.get(archive_context, :name, Map.get(archive_context, "name")),
      month: Map.get(archive_context, :month, Map.get(archive_context, "month")),
      year: Map.get(archive_context, :year, Map.get(archive_context, "year")),
      day: Map.get(archive_context, :day, Map.get(archive_context, "day"))
    }
  end

  defp build_day_blocks(posts) do
    grouped_blocks =
      posts
      |> Enum.filter(&is_integer(Map.get(&1, :created_at)))
      |> Enum.group_by(&DateTime.from_unix!(Map.get(&1, :created_at)) |> DateTime.to_date() |> Date.to_iso8601())
      |> Enum.sort_by(fn {label, _posts} -> label end)

    grouped_blocks
    |> Enum.with_index()
    |> Enum.map(fn {{date_label, grouped_posts}, index} ->
      %{
        date_label: date_label,
        show_date_marker: true,
        show_separator: index < length(grouped_blocks) - 1,
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

  defp html_theme_attribute(nil), do: nil
  defp html_theme_attribute(""), do: nil
  defp html_theme_attribute(theme), do: ~s(data-theme="#{theme}")

  defp default_pico_stylesheet_href, do: "/assets/pico.min.css"

  defp href_for_language(""), do: "/"
  defp href_for_language(prefix), do: prefix <> "/"

  defp calendar_initial_year(%{created_at: created_at}) when is_integer(created_at),
    do: DateTime.from_unix!(created_at).year

  defp calendar_initial_year(_post), do: nil

  defp calendar_initial_month(%{created_at: created_at}) when is_integer(created_at),
    do: DateTime.from_unix!(created_at).month

  defp calendar_initial_month(_post), do: nil

  defp calendar_initial_year_from_posts([post | _rest]), do: calendar_initial_year(post)
  defp calendar_initial_year_from_posts([]), do: nil

  defp calendar_initial_month_from_posts([post | _rest]), do: calendar_initial_month(post)
  defp calendar_initial_month_from_posts([]), do: nil

  defp language_prefix(language, main_language) when language == main_language, do: ""
  defp language_prefix(nil, _main_language), do: ""
  defp language_prefix(language, _main_language), do: "/#{language}"

  defp normalize_language(nil, fallback), do: fallback
  defp normalize_language("", fallback), do: fallback

  defp normalize_language(language, _fallback) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end
end
