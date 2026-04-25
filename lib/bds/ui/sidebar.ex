defmodule BDS.UI.Sidebar do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.ChatConversation
  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  @page_category "page"
  @default_page_size 500

  def snapshot(nil), do: empty_snapshot()

  def snapshot(project_id) when is_binary(project_id) do
    %{
      "posts" => view(project_id, "posts"),
      "pages" => view(project_id, "pages"),
      "media" => view(project_id, "media"),
      "scripts" => view(project_id, "scripts"),
      "templates" => view(project_id, "templates"),
      "tags" => view(project_id, "tags"),
      "chat" => view(project_id, "chat"),
      "import" => entity_list_view("Import", "Import definitions", "import", []),
      "git" => git_view(),
      "settings" => settings_nav_view()
    }
  end

  def view(project_id, view_id, params \\ %{})

  def view(nil, view_id, _params), do: empty_view(view_id)

  def view(project_id, view_id, params) when is_binary(project_id) do
    normalized_view = normalize_view_id(view_id)

    case normalized_view do
      "posts" -> posts_view(project_id, params, false)
      "pages" -> posts_view(project_id, params, true)
      "media" -> media_view(project_id, params)
      "scripts" -> entity_list_view("Scripts", "Automation helpers", "scripts", list_scripts(project_id))
      "templates" -> entity_list_view("Templates", "Site rendering", "templates", list_templates(project_id))
      "tags" -> tags_nav_view(list_tags(project_id))
      "chat" -> entity_list_view("Chat", "AI conversations", "chat", list_conversations())
      "import" -> entity_list_view("Import", "Import definitions", "import", [])
      "git" -> git_view()
      "settings" -> settings_nav_view()
      _other -> empty_view(normalized_view)
    end
  end

  def empty_snapshot do
    %{
      "posts" => empty_view("posts"),
      "pages" => empty_view("pages"),
      "media" => empty_view("media"),
      "scripts" => entity_list_view("Scripts", "Automation helpers", "scripts", []),
      "templates" => entity_list_view("Templates", "Site rendering", "templates", []),
      "tags" => tags_nav_view([]),
      "chat" => entity_list_view("Chat", "AI conversations", "chat", []),
      "import" => entity_list_view("Import", "Import definitions", "import", []),
      "git" => git_view(),
      "settings" => settings_nav_view()
    }
  end

  defp empty_view("posts"), do: posts_view_data([], [], %{}, false, empty_filter_params())
  defp empty_view("pages"), do: posts_view_data([], [], %{}, true, empty_filter_params())
  defp empty_view("media"), do: media_view_data([], [], empty_filter_params())
  defp empty_view("scripts"), do: entity_list_view("Scripts", "Automation helpers", "scripts", [])
  defp empty_view("templates"), do: entity_list_view("Templates", "Site rendering", "templates", [])
  defp empty_view("tags"), do: tags_nav_view([])
  defp empty_view("chat"), do: entity_list_view("Chat", "AI conversations", "chat", [])
  defp empty_view("import"), do: entity_list_view("Import", "Import definitions", "import", [])
  defp empty_view("git"), do: git_view()
  defp empty_view("settings"), do: settings_nav_view()
  defp empty_view(_other), do: %{title: "", subtitle: "", layout: "entity_list", items: [], empty_message: "No items"}

  defp posts_view(project_id, params, pages?) do
    posts = list_posts(project_id)
    translation_counts = translation_counts(project_id)
    filters = normalize_filter_params(params)
    base_posts = Enum.filter(posts, &(page_post?(&1) == pages?))
    filtered_posts = apply_post_filters(base_posts, filters)

    posts_view_data(base_posts, filtered_posts, translation_counts, pages?, filters)
  end

  defp posts_view_data(base_posts, filtered_posts, translation_counts, pages?, filters) do
    limited_posts = Enum.take(filtered_posts, filters.display_limit)
    grouped_posts = group_posts(limited_posts)

    %{
      title: if(pages?, do: "Pages", else: "Posts"),
      subtitle: if(pages?, do: "Standalone pages", else: "Drafts, published entries, and archive history"),
      layout: "post_list",
      empty_message: if(pages?, do: "sidebar.noPagesYet", else: "sidebar.noPostsYet"),
      filters: %{
        enabled: true,
        search_placeholder: if(pages?, do: "sidebar.searchPagesPlaceholder", else: "sidebar.searchPostsPlaceholder"),
        toggle_filters_label: "sidebar.toggleFilters",
        archive_label: "render.archive",
        tags_label: "sidebar.tags",
        categories_label: "sidebar.categories",
        clear_tags_label: "sidebar.clearTags",
        clear_categories_label: "sidebar.clearCategories",
        clear_filters_label: "sidebar.clearFilters",
        results_label: "sidebar.results",
        results_for_label: "sidebar.resultsFor",
        no_results_label: "sidebar.noMatchingPosts",
        year_month_counts: year_month_counts(base_posts, &post_filter_timestamp/1),
        available_tags: available_tags(base_posts, & &1.tags),
        available_categories: available_categories(base_posts, pages?),
        max_items: @default_page_size,
        display_limit: filters.display_limit,
        loaded_count: length(limited_posts),
        total_count: length(filtered_posts),
        has_more: length(filtered_posts) > filters.display_limit,
        has_active_filters: filter_active?(filters),
        selected: %{
          search: filters.search,
          year: filters.year,
          month: filters.month,
          tags: filters.tags,
          categories: filters.categories
        }
      },
      sections: [
        build_post_section("Drafts", :draft, grouped_posts.draft, translation_counts, false),
        build_post_section("Published", :published, grouped_posts.published, translation_counts, true),
        build_post_section("Archived", :archived, grouped_posts.archived, translation_counts, false)
      ]
    }
  end

  defp media_view(project_id, params) do
    media_items = list_media(project_id)
    filters = normalize_filter_params(params)
    filtered_media = apply_media_filters(media_items, filters)

    media_view_data(media_items, filtered_media, filters)
  end

  defp media_view_data(base_media, filtered_media, filters) do
    limited_media = Enum.take(filtered_media, filters.display_limit)

    %{
      title: "Media",
      subtitle: "Images and files",
      layout: "media_grid",
      empty_message: "sidebar.noMediaFiles",
      filters: %{
        enabled: true,
        search_placeholder: "sidebar.searchMediaPlaceholder",
        toggle_filters_label: "sidebar.toggleFilters",
        archive_label: "render.archive",
        tags_label: "sidebar.tags",
        clear_tags_label: "sidebar.clearTags",
        clear_filters_label: "sidebar.clearFilters",
        results_label: "sidebar.results",
        results_for_label: "sidebar.resultsFor",
        no_results_label: "sidebar.noMediaFiles",
        year_month_counts: year_month_counts(base_media, &Map.get(&1, :updated_at)),
        available_tags: available_tags(base_media, & &1.tags),
        available_categories: [],
        max_items: @default_page_size,
        display_limit: filters.display_limit,
        loaded_count: length(limited_media),
        total_count: length(filtered_media),
        has_more: length(filtered_media) > filters.display_limit,
        has_active_filters: filter_active?(filters),
        selected: %{
          search: filters.search,
          year: filters.year,
          month: filters.month,
          tags: filters.tags,
          categories: []
        }
      },
      items:
        Enum.map(limited_media, fn media ->
          %{
            id: media.id,
            title: display_media_title(media),
            meta: media_size_label(media.size),
            mime_type: media.mime_type,
            route: "media",
            updated_at: media.updated_at,
            tags: media.tags || [],
            search_blob: media_search_blob(media)
          }
        end)
    }
  end

  defp tags_nav_view(tags) do
    %{
      title: "Tags",
      subtitle: "Tag management",
      layout: "nav_list",
      items: [
        %{id: "tags-cloud", title: "Tag Cloud", icon: "☁️", route: "tags"},
        %{id: "tags-manage", title: "Create / Edit", icon: "✏️", route: "tags"},
        %{id: "tags-merge", title: "Merge Tags", icon: "🔀", route: "tags"}
      ],
      summary_badge: length(tags)
    }
  end

  defp settings_nav_view do
    %{
      title: "Settings",
      subtitle: "Project and publishing",
      layout: "nav_list",
      items: [
        %{id: "settings-project", title: "Project", icon: "📁", route: "settings"},
        %{id: "settings-editor", title: "Editor", icon: "📝", route: "settings"},
        %{id: "settings-content", title: "Content", icon: "📋", route: "settings"},
        %{id: "settings-ai", title: "AI", icon: "🤖", route: "settings"},
        %{id: "settings-technology", title: "Technology", icon: "⚙️", route: "settings"},
        %{id: "settings-publishing", title: "Publishing", icon: "🚀", route: "settings"},
        %{id: "settings-data", title: "Data", icon: "🗄️", route: "settings"},
        %{id: "settings-mcp", title: "MCP", icon: "🔌", route: "settings"},
        %{id: "settings-style", title: "Style", icon: "🎨", route: "style"}
      ]
    }
  end

  defp git_view do
    %{
      title: "Git",
      subtitle: "Working tree and history",
      layout: "entity_list",
      empty_message: "No items",
      items: [
        %{id: "git-working-tree", title: "Working tree", meta: "Working tree and history", route: "git_diff", updated_at: nil}
      ]
    }
  end

  defp entity_list_view(title, subtitle, route, items) do
    %{
      title: title,
      subtitle: subtitle,
      layout: "entity_list",
      empty_message: "No items",
      items:
        Enum.map(items, fn item ->
          %{
            id: item.id,
            title: item.title,
            meta: Map.get(item, :meta),
            updated_at: Map.get(item, :updated_at),
            route: route
          }
        end)
    }
  end

  defp build_post_section(title, status, posts, translation_counts, published_meta?) do
    %{
      id: Atom.to_string(status),
      title: title,
      status: Atom.to_string(status),
      count: length(posts),
      items:
        Enum.map(posts, fn post ->
          %{
            id: post.id,
            title: display_post_title(post),
            categories: post.categories || [],
            tags: post.tags || [],
            status: Atom.to_string(post.status),
            language_count: 1 + Map.get(translation_counts, post.id, 0),
            meta_timestamp: if(published_meta?, do: post.published_at || post.updated_at, else: post.updated_at),
            route: "post",
            search_blob: post_search_blob(post)
          }
        end)
    }
  end

  defp list_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at, desc: post.created_at],
        select: %{
          id: post.id,
          title: post.title,
          slug: post.slug,
          excerpt: post.excerpt,
          status: post.status,
          tags: post.tags,
          categories: post.categories,
          updated_at: post.updated_at,
          published_at: post.published_at,
          language: post.language
        }
    )
  end

  defp translation_counts(project_id) do
    Repo.all(
      from translation in Translation,
        where: translation.project_id == ^project_id,
        group_by: translation.translation_for,
        select: {translation.translation_for, count(translation.id)}
    )
    |> Map.new()
  end

  defp list_media(project_id) do
    Repo.all(
      from media in Media,
        where: media.project_id == ^project_id,
        order_by: [desc: media.updated_at, desc: media.created_at],
        select: %{
          id: media.id,
          title: media.title,
          original_name: media.original_name,
          mime_type: media.mime_type,
          size: media.size,
          tags: media.tags,
          alt: media.alt,
          caption: media.caption,
          updated_at: media.updated_at
        }
    )
  end

  defp list_scripts(project_id) do
    Repo.all(
      from script in Script,
        where: script.project_id == ^project_id,
        order_by: [desc: script.updated_at, desc: script.created_at],
        select: %{id: script.id, title: script.title, updated_at: script.updated_at}
    )
  end

  defp list_templates(project_id) do
    Repo.all(
      from template in Template,
        where: template.project_id == ^project_id,
        order_by: [desc: template.updated_at, desc: template.created_at],
        select: %{id: template.id, title: template.title, updated_at: template.updated_at}
    )
  end

  defp list_tags(project_id) do
    Repo.all(
      from tag in Tag,
        where: tag.project_id == ^project_id,
        order_by: [asc: tag.name],
        select: %{id: tag.id, title: tag.name, updated_at: tag.updated_at}
    )
  end

  defp list_conversations do
    Repo.all(
      from conversation in ChatConversation,
        order_by: [desc: conversation.updated_at, desc: conversation.created_at],
        select: %{id: conversation.id, title: conversation.title, updated_at: conversation.updated_at}
    )
  end

  defp group_posts(posts) do
    Enum.reduce(posts, %{draft: [], published: [], archived: []}, fn post, acc ->
      case post.status do
        :draft -> %{acc | draft: acc.draft ++ [post]}
        :published -> %{acc | published: acc.published ++ [post]}
        :archived -> %{acc | archived: acc.archived ++ [post]}
        _other -> acc
      end
    end)
  end

  defp page_post?(post) do
    Enum.any?(post.categories || [], &(String.downcase(to_string(&1)) == @page_category))
  end

  defp normalize_view_id(view_id) when is_atom(view_id), do: Atom.to_string(view_id)
  defp normalize_view_id(view_id) when is_binary(view_id), do: view_id
  defp normalize_view_id(_other), do: ""

  defp normalize_filter_params(params) when is_map(params) do
    %{
      search: normalize_string(Map.get(params, "search") || Map.get(params, :search)),
      year: normalize_integer(Map.get(params, "year") || Map.get(params, :year)),
      month: normalize_integer(Map.get(params, "month") || Map.get(params, :month)),
      tags: normalize_string_list(Map.get(params, "tags") || Map.get(params, :tags)),
      categories: normalize_string_list(Map.get(params, "categories") || Map.get(params, :categories)),
      display_limit:
        max(
          @default_page_size,
          normalize_integer(Map.get(params, "display_limit") || Map.get(params, :display_limit)) || @default_page_size
        )
    }
  end

  defp normalize_filter_params(_params), do: empty_filter_params()

  defp empty_filter_params do
    %{search: nil, year: nil, month: nil, tags: [], categories: [], display_limit: @default_page_size}
  end

  defp filter_active?(filters) do
    present?(filters.search) or not is_nil(filters.year) or filters.tags != [] or filters.categories != []
  end

  defp apply_post_filters(posts, filters) do
    Enum.filter(posts, fn post ->
      matches_search?(post_search_blob(post), filters.search) and
        matches_year_month?(post_filter_timestamp(post), filters.year, filters.month) and
        matches_overlap?(post.tags, filters.tags) and
        matches_overlap?(filtered_categories(post.categories), filters.categories)
    end)
  end

  defp apply_media_filters(media_items, filters) do
    Enum.filter(media_items, fn media ->
      matches_search?(media_search_blob(media), filters.search) and
        matches_year_month?(media.updated_at, filters.year, filters.month) and
        matches_overlap?(media.tags, filters.tags)
    end)
  end

  defp matches_search?(_text, nil), do: true

  defp matches_search?(text, search) do
    String.contains?(String.downcase(text), String.downcase(search))
  end

  defp matches_year_month?(_timestamp, nil, _month), do: true
  defp matches_year_month?(nil, _year, _month), do: false

  defp matches_year_month?(timestamp, year, month) do
    datetime = DateTime.from_unix!(timestamp, :millisecond)

    datetime.year == year and
      (is_nil(month) or datetime.month == month)
  end

  defp matches_overlap?(_values, []), do: true

  defp matches_overlap?(values, filters) do
    normalized_values = MapSet.new(Enum.map(values || [], &normalize_term/1))

    Enum.all?(filters, fn filter ->
      MapSet.member?(normalized_values, normalize_term(filter))
    end)
  end

  defp year_month_counts(items, timestamp_fun) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case timestamp_fun.(item) do
        timestamp when is_integer(timestamp) ->
          datetime = DateTime.from_unix!(timestamp, :millisecond)
          Map.update(acc, {datetime.year, datetime.month}, 1, &(&1 + 1))

        _other ->
          acc
      end
    end)
    |> Enum.map(fn {{year, month}, count} -> %{year: year, month: month, count: count} end)
    |> Enum.sort_by(fn entry -> {-entry.year, -entry.month} end)
  end

  defp available_tags(items, getter) do
    items
    |> Enum.flat_map(fn item -> getter.(item) || [] end)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.downcase/1)
  end

  defp available_categories(posts, pages?) do
    posts
    |> Enum.flat_map(&filtered_categories(&1.categories || []))
    |> then(fn categories ->
      if pages?, do: Enum.reject(categories, &(normalize_term(&1) == @page_category)), else: categories
    end)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort_by(&String.downcase/1)
  end

  defp filtered_categories(categories) do
    Enum.reject(categories || [], &(normalize_term(&1) == @page_category))
  end

  defp post_filter_timestamp(post), do: post.published_at || post.updated_at

  defp post_search_blob(post) do
    [post.title, post.slug, post.excerpt, Enum.join(post.tags || [], " "), Enum.join(post.categories || [], " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp media_search_blob(media) do
    [media.title, media.original_name, media.alt, media.caption, Enum.join(media.tags || [], " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp normalize_integer(nil), do: nil
  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_term(value), do: value |> to_string() |> String.downcase()

  defp display_post_title(post) do
    cond do
      present?(post.title) -> post.title
      present?(post.slug) -> post.slug
      true -> "Untitled"
    end
  end

  defp display_media_title(media) do
    if present?(media.title), do: media.title, else: media.original_name || ""
  end

  defp media_size_label(size) when is_integer(size) and size < 1024, do: "#{size} B"

  defp media_size_label(size) when is_integer(size) and size < 1024 * 1024 do
    :erlang.float_to_binary(size / 1024, decimals: 1) <> " KB"
  end

  defp media_size_label(size) when is_integer(size) do
    :erlang.float_to_binary(size / (1024 * 1024), decimals: 1) <> " MB"
  end

  defp media_size_label(_size), do: "0 B"

  defp present?(value), do: value not in [nil, ""]
end
