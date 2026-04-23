defmodule BDS.Rendering do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Rendering.FileSystem
  alias BDS.Menu
  alias BDS.Metadata
  alias BDS.Projects
  alias BDS.Rendering.Filters
  alias BDS.Rendering.I18n
  alias BDS.Repo
  alias BDS.Tags.Tag
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Templates.Template

  def render_post_page(project_id, template_slug, assigns) when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :post, template_slug),
         {:ok, rendered} <- render_template(project_id, template_source, post_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_list_page(project_id, assigns) when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :list, nil),
         {:ok, rendered} <- render_template(project_id, template_source, list_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_not_found_page(project_id, assigns \\ %{}) when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- load_template_source(project_id, :not_found, nil),
         {:ok, rendered} <- render_template(project_id, template_source, not_found_assigns(project_id, assigns)) do
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
          template.project_id == ^project_id and template.kind == ^kind and template.status == :published and
            template.enabled == true and template.slug == ^slug,
        limit: 1
    ) || select_template(project_id, kind, nil)
  end

  defp select_template(project_id, kind, nil) do
    Repo.one(
      from template in Template,
        where:
          template.project_id == ^project_id and template.kind == ^kind and template.status == :published and
            template.enabled == true,
        order_by: [asc: template.created_at, asc: template.slug],
        limit: 1
    )
  end

  defp published_template_body(%Template{content: content}) when is_binary(content), do: {:ok, content}

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
    language = Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))
    main_language = metadata.main_language || language
    post_record = load_post_record(assigns)
    post_categories = Map.get(post_record || %{}, :categories, []) || []
    post_tags = Map.get(post_record || %{}, :tags, []) || []

    %{
      language: language,
      language_prefix: Map.get(assigns, :language_prefix, Map.get(assigns, "language_prefix", language_prefix(language, main_language))),
      page_title: Map.get(assigns, :page_title, Map.get(assigns, "page_title", Map.get(assigns, :title, Map.get(assigns, "title")))),
      pico_stylesheet_href: nil,
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      alternate_links: [],
      menu_items: menu_items(project_id),
      calendar_initial_year: calendar_initial_year(post_record),
      calendar_initial_month: calendar_initial_month(post_record),
      post_categories: post_categories,
      post_tags: post_tags,
      tag_color_by_name: tag_color_by_name(project_id),
      backlinks: [],
      canonical_post_path_by_slug: canonical_post_path_by_slug(project_id, main_language),
      canonical_media_path_by_source_path: canonical_media_path_by_source_path(project_id),
      post_data_json_by_id: post_data_json(assigns),
      post: %{
        id: Map.get(assigns, :id, Map.get(assigns, "id")),
        slug: Map.get(assigns, :slug, Map.get(assigns, "slug")),
        title: Map.get(assigns, :title, Map.get(assigns, "title")),
        content: Map.get(assigns, :content, Map.get(assigns, "content")),
        excerpt: Map.get(assigns, :excerpt, Map.get(assigns, "excerpt")),
        language: Map.get(assigns, :language, Map.get(assigns, "language")),
        show_title: true
      }
    }
  end

  defp list_assigns(project_id, assigns) do
    metadata = project_metadata(project_id)
    language = Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))
    main_language = metadata.main_language || language
    posts = normalize_list_posts(Map.get(assigns, :posts, Map.get(assigns, "posts", [])))
    archive_context = Map.get(assigns, :archive_context, Map.get(assigns, "archive_context", %{}))

    %{
      language: language,
      language_prefix: Map.get(assigns, :language_prefix, Map.get(assigns, "language_prefix", language_prefix(language, main_language))),
      page_title: Map.get(assigns, :page_title, Map.get(assigns, "page_title")),
      posts: posts,
      pico_stylesheet_href: nil,
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      alternate_links: [],
      menu_items: menu_items(project_id),
      calendar_initial_year: calendar_initial_year_from_posts(posts),
      calendar_initial_month: calendar_initial_month_from_posts(posts),
      archive_context: normalize_archive_context(archive_context),
      show_archive_range_heading: false,
      min_date: nil,
      max_date: nil,
      is_list_page: true,
      is_first_page: true,
      is_last_page: true,
      has_prev_page: false,
      has_next_page: false,
      prev_page_href: "",
      next_page_href: "",
      canonical_post_path_by_slug: canonical_post_path_by_slug(project_id, main_language),
      canonical_media_path_by_source_path: canonical_media_path_by_source_path(project_id),
      post_data_json_by_id: Enum.into(posts, %{}, fn post -> {post.id, Jason.encode!(Map.take(post, [:id, :slug, :title, :content]))} end),
      day_blocks: [
        %{
          date_label: "",
          show_date_marker: false,
          show_separator: false,
          posts: posts
        }
      ]
    }
  end

  defp not_found_assigns(project_id, assigns) do
    metadata = project_metadata(project_id)
    language = Map.get(assigns, :language, Map.get(assigns, "language", metadata.main_language || "en"))
    main_language = metadata.main_language || language

    %{
      page_title: Map.get(assigns, :page_title, Map.get(assigns, "page_title", "404 Not Found")),
      language: language,
      language_prefix: Map.get(assigns, :language_prefix, Map.get(assigns, "language_prefix", language_prefix(language, main_language))),
      pico_stylesheet_href: nil,
      html_theme_attribute: html_theme_attribute(metadata.pico_theme),
      blog_languages: blog_languages(metadata, language),
      menu_items: menu_items(project_id),
      alternate_links: [],
      not_found_message: Map.get(assigns, :not_found_message, Map.get(assigns, "not_found_message")),
      not_found_back_label: Map.get(assigns, :not_found_back_label, Map.get(assigns, "not_found_back_label"))
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
  defp menu_item_href(%{kind: :page, slug: slug}) when is_binary(slug) and slug != "", do: "/#{slug}/"
  defp menu_item_href(%{kind: :category_archive, slug: slug}) when is_binary(slug) and slug != "", do: "/category/#{URI.encode(slug)}/"
  defp menu_item_href(%{kind: :submenu}), do: "#"
  defp menu_item_href(_item), do: "#"

  defp blog_languages(metadata, current_language) do
    ([metadata.main_language] ++ (metadata.blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.map(fn language ->
      normalized = I18n.normalize_language(language)

      %{
        code: normalized,
        flag: I18n.flag(normalized),
        href_prefix: language_prefix(normalized, metadata.main_language || current_language),
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

  defp post_data_json(assigns) do
    id = Map.get(assigns, :id, Map.get(assigns, "id"))

    if is_binary(id) do
      %{
        id =>
          Jason.encode!(%{
            id: id,
            slug: Map.get(assigns, :slug, Map.get(assigns, "slug")),
            title: Map.get(assigns, :title, Map.get(assigns, "title")),
            content: Map.get(assigns, :content, Map.get(assigns, "content"))
          })
      }
    else
      %{}
    end
  end

  defp canonical_post_path_by_slug(project_id, main_language) do
    posts = Repo.all(from post in Post, where: post.project_id == ^project_id and post.status == :published)

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

  defp post_path(post, language_prefix) when is_binary(language_prefix) and language_prefix != "" do
    Path.join([String.trim_leading(language_prefix, "/"), post_path(post, nil)])
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
    |> then(&"/" <> String.trim_trailing(&1, "index.html"))
  end

  defp post_path(post, language, main_language) do
    prefix = language_prefix(language, main_language)
    post_path(post, prefix)
  end

  defp normalize_list_posts(posts) do
    Enum.map(posts, fn post ->
      %{
        id: Map.get(post, :id, Map.get(post, "id")),
        slug: Map.get(post, :slug, Map.get(post, "slug")),
        title: Map.get(post, :title, Map.get(post, "title")),
        content: Map.get(post, :content, Map.get(post, "content", Map.get(post, :excerpt, Map.get(post, "excerpt", "")))),
        show_title: true
      }
    end)
  end

  defp normalize_archive_context(nil), do: nil
  defp normalize_archive_context(%{} = archive_context), do: archive_context

  defp html_theme_attribute(nil), do: nil
  defp html_theme_attribute(""), do: nil
  defp html_theme_attribute(theme), do: ~s(data-theme="#{theme}")

  defp calendar_initial_year(%{created_at: created_at}) when is_integer(created_at), do: DateTime.from_unix!(created_at).year
  defp calendar_initial_year(_post), do: nil

  defp calendar_initial_month(%{created_at: created_at}) when is_integer(created_at), do: DateTime.from_unix!(created_at).month
  defp calendar_initial_month(_post), do: nil

  defp calendar_initial_year_from_posts([post | _rest]), do: calendar_initial_year(post)
  defp calendar_initial_year_from_posts([]), do: nil

  defp calendar_initial_month_from_posts([post | _rest]), do: calendar_initial_month(post)
  defp calendar_initial_month_from_posts([]), do: nil

  defp language_prefix(language, main_language) when language == main_language, do: ""
  defp language_prefix(nil, _main_language), do: ""
  defp language_prefix(language, _main_language), do: "/#{language}"
end
