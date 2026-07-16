defmodule BDS.UI.Sidebar do
  @moduledoc false

  import Ecto.Query
  use Gettext, backend: BDS.Gettext

  alias BDS.AI.ChatConversation
  alias BDS.ImportDefinitions
  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  @default_page_size 500

  @spec snapshot(String.t() | nil) :: map()
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
      "import" =>
        entity_list_view(
          dgettext("ui", "Import"),
          dgettext("ui", "Import definitions"),
          "import",
          list_import_definitions(project_id)
        ),
      "git" => git_view(project_id),
      "settings" => settings_nav_view()
    }
  end

  @spec view(String.t() | nil, String.t() | atom(), map()) :: map()
  def view(project_id, view_id, params \\ %{})

  def view(nil, view_id, _params), do: empty_view(view_id)

  def view(project_id, view_id, params) when is_binary(project_id) do
    normalized_view = normalize_view_id(view_id)

    case normalized_view do
      "posts" ->
        posts_view(project_id, params, false)

      "pages" ->
        posts_view(project_id, params, true)

      "media" ->
        media_view(project_id, params)

      "scripts" ->
        entity_list_view(
          dgettext("ui", "Scripts"),
          dgettext("ui", "Automation helpers"),
          "scripts",
          list_scripts(project_id)
        )

      "templates" ->
        entity_list_view(
          dgettext("ui", "Templates"),
          dgettext("ui", "Site rendering"),
          "templates",
          list_templates(project_id)
        )

      "tags" ->
        tags_nav_view(tag_count(project_id))

      "chat" ->
        entity_list_view(
          dgettext("ui", "Chat"),
          dgettext("ui", "AI conversations"),
          "chat",
          list_conversations()
        )

      "import" ->
        entity_list_view(
          dgettext("ui", "Import"),
          dgettext("ui", "Import definitions"),
          "import",
          list_import_definitions(project_id)
        )

      "git" ->
        git_view(project_id)

      "settings" ->
        settings_nav_view()

      _other ->
        empty_view(normalized_view)
    end
  end

  @spec empty_snapshot() :: map()
  def empty_snapshot do
    %{
      "posts" => empty_view("posts"),
      "pages" => empty_view("pages"),
      "media" => empty_view("media"),
      "scripts" =>
        entity_list_view(
          dgettext("ui", "Scripts"),
          dgettext("ui", "Automation helpers"),
          "scripts",
          []
        ),
      "templates" =>
        entity_list_view(
          dgettext("ui", "Templates"),
          dgettext("ui", "Site rendering"),
          "templates",
          []
        ),
      "tags" => tags_nav_view(0),
      "chat" =>
        entity_list_view(
          dgettext("ui", "Chat"),
          dgettext("ui", "AI conversations"),
          "chat",
          []
        ),
      "import" =>
        entity_list_view(
          dgettext("ui", "Import"),
          dgettext("ui", "Import definitions"),
          "import",
          []
        ),
      "git" => git_view(nil),
      "settings" => settings_nav_view()
    }
  end

  defp empty_view("posts"),
    do: build_posts_view([], %{}, false, empty_filter_params(), %{}, [], [], [])

  defp empty_view("pages"),
    do: build_posts_view([], %{}, true, empty_filter_params(), %{}, [], [], [])

  defp empty_view("media"), do: build_media_view([], empty_filter_params(), %{}, [], [], 0)

  defp empty_view("scripts"),
    do:
      entity_list_view(
        dgettext("ui", "Scripts"),
        dgettext("ui", "Automation helpers"),
        "scripts",
        []
      )

  defp empty_view("templates"),
    do:
      entity_list_view(
        dgettext("ui", "Templates"),
        dgettext("ui", "Site rendering"),
        "templates",
        []
      )

  defp empty_view("tags"), do: tags_nav_view(0)

  defp empty_view("chat"),
    do:
      entity_list_view(
        dgettext("ui", "Chat"),
        dgettext("ui", "AI conversations"),
        "chat",
        []
      )

  defp empty_view("import"),
    do:
      entity_list_view(
        dgettext("ui", "Import"),
        dgettext("ui", "Import definitions"),
        "import",
        []
      )

  defp empty_view("git"), do: git_view(nil)
  defp empty_view("settings"), do: settings_nav_view()

  defp empty_view(_other),
    do: %{
      title: "",
      subtitle: "",
      layout: "entity_list",
      items: [],
      empty_message: dgettext("ui", "No items")
    }

  # ---------------------------------------------------------------------------
  # Posts view (SQL-level filtering)
  # ---------------------------------------------------------------------------

  defp posts_view(project_id, params, pages?) do
    filters = normalize_filter_params(params)
    translation_counts = translation_counts(project_id)
    tag_colors = tag_color_map(project_id)

    year_months = base_year_month_counts(project_id, pages?)
    avail_tags = base_available_tags(project_id, pages?)
    avail_categories = base_available_categories(project_id, pages?)

    filtered_query =
      base_posts_query(project_id, pages?)
      |> apply_post_query_filters(filters)

    total_count = Repo.one(from p in filtered_query, select: count(p.id))

    limited_posts =
      Repo.all(
        from p in filtered_query,
          order_by: [desc: p.created_at],
          limit: ^filters.display_limit,
          select: %{
            id: p.id,
            title: p.title,
            slug: p.slug,
            excerpt: p.excerpt,
            status: p.status,
            tags: p.tags,
            categories: p.categories,
            updated_at: p.updated_at,
            published_at: p.published_at,
            language: p.language
          }
      )

    build_posts_view(
      limited_posts,
      translation_counts,
      pages?,
      filters,
      tag_colors,
      year_months,
      avail_tags,
      avail_categories,
      total_count
    )
  end

  defp build_posts_view(
         limited_posts,
         translation_counts,
         pages?,
         filters,
         tag_colors,
         year_month_counts,
         available_tags,
         available_categories,
         total_count \\ 0
       ) do
    grouped_posts = group_posts(limited_posts)
    loaded_count = length(limited_posts)

    %{
      title: if(pages?, do: dgettext("ui", "Pages"), else: dgettext("ui", "Posts")),
      subtitle:
        if(pages?,
          do: dgettext("ui", "Standalone pages"),
          else: dgettext("ui", "Drafts, published entries, and archive history")
        ),
      layout: "post_list",
      empty_message:
        if(pages?, do: dgettext("ui", "No pages yet"), else: dgettext("ui", "No posts yet")),
      filters: %{
        enabled: true,
        search_placeholder:
          if(pages?,
            do: dgettext("ui", "Search pages..."),
            else: dgettext("ui", "Search posts...")
          ),
        toggle_filters_label: dgettext("ui", "Toggle Filters"),
        archive_label: dgettext("render", "Archive"),
        tags_label: dgettext("ui", "Tags"),
        categories_label: dgettext("ui", "Categories"),
        clear_tags_label: dgettext("ui", "Clear tags"),
        clear_categories_label: dgettext("ui", "Clear categories"),
        clear_filters_label: dgettext("ui", "Clear filters"),
        results_label: dgettext("ui", "results"),
        results_for_label: dgettext("ui", "results for"),
        no_results_label: dgettext("ui", "No matching posts"),
        year_month_counts: year_month_counts,
        available_tags: available_tags,
        available_tag_colors: Map.take(tag_colors, available_tags),
        available_categories: available_categories,
        max_items: @default_page_size,
        display_limit: filters.display_limit,
        loaded_count: loaded_count,
        total_count: total_count,
        has_more: total_count > filters.display_limit,
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
        build_post_section(
          dgettext("ui", "Drafts"),
          :draft,
          grouped_posts.draft,
          translation_counts,
          false
        ),
        build_post_section(
          dgettext("ui", "Published"),
          :published,
          grouped_posts.published,
          translation_counts,
          true
        ),
        build_post_section(
          dgettext("ui", "Archived"),
          :archived,
          grouped_posts.archived,
          translation_counts,
          false
        )
      ]
    }
  end

  defp base_posts_query(project_id, true = _pages?) do
    from post in Post,
      where: post.project_id == ^project_id,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = 'page')",
          post.categories
        )
  end

  defp base_posts_query(project_id, false = _pages?) do
    from post in Post,
      where: post.project_id == ^project_id,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = 'page')",
          post.categories
        )
  end

  defp apply_post_query_filters(query, filters) do
    query
    |> maybe_where_search(filters.search)
    |> maybe_where_year(filters.year)
    |> maybe_where_month(filters.month)
    |> maybe_where_day(filters.day)
    |> maybe_where_all_tags(filters.tags)
    |> maybe_where_all_categories(filters.categories)
  end

  defp maybe_where_search(query, nil), do: query

  defp maybe_where_search(query, search) do
    search_term = "%" <> String.downcase(search) <> "%"

    where(
      query,
      [p],
      fragment(
        """
        lower(COALESCE(?,'') || ' ' || COALESCE(?,'') || ' ' || COALESCE(?,'')
              || ' ' || COALESCE(?,'[]') || ' ' || COALESCE(?,'[]')) LIKE ?
        """,
        p.title,
        p.slug,
        p.excerpt,
        p.tags,
        p.categories,
        ^search_term
      )
    )
  end

  defp maybe_where_year(query, nil), do: query

  defp maybe_where_year(query, year) do
    year_str = to_string(year)

    where(
      query,
      [p],
      fragment(
        "strftime('%Y', datetime(COALESCE(?, ?) / 1000, 'unixepoch')) = ?",
        p.published_at,
        p.updated_at,
        ^year_str
      )
    )
  end

  defp maybe_where_month(query, nil), do: query

  defp maybe_where_month(query, month) do
    month_str = String.pad_leading(to_string(month), 2, "0")

    where(
      query,
      [p],
      fragment(
        "strftime('%m', datetime(COALESCE(?, ?) / 1000, 'unixepoch')) = ?",
        p.published_at,
        p.updated_at,
        ^month_str
      )
    )
  end

  # Day-of-month filter used by the TUI's ISO-date search (yyyy-mm-dd);
  # always combined with year and month by the caller.
  defp maybe_where_day(query, nil), do: query

  defp maybe_where_day(query, day) do
    day_str = String.pad_leading(to_string(day), 2, "0")

    where(
      query,
      [p],
      fragment(
        "strftime('%d', datetime(COALESCE(?, ?) / 1000, 'unixepoch')) = ?",
        p.published_at,
        p.updated_at,
        ^day_str
      )
    )
  end

  defp maybe_where_all_tags(query, []), do: query

  defp maybe_where_all_tags(query, tags), do: where_all_in_json_array(query, tags, :tags)

  defp maybe_where_all_categories(query, []), do: query

  defp maybe_where_all_categories(query, categories),
    do: where_all_in_json_array(query, categories, :categories, true)

  defp base_year_month_counts(project_id, pages?) do
    is_page = if pages?, do: 1, else: 0

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT CAST(strftime('%Y', datetime(COALESCE(published_at, updated_at) / 1000, 'unixepoch')) AS INTEGER),
               CAST(strftime('%m', datetime(COALESCE(published_at, updated_at) / 1000, 'unixepoch')) AS INTEGER),
               COUNT(*)
        FROM posts
        WHERE project_id = ?1
          AND COALESCE(published_at, updated_at) IS NOT NULL
          AND (
            (?2 = 1 AND EXISTS (SELECT 1 FROM json_each(categories) WHERE lower(value) = 'page'))
            OR
            (?2 = 0 AND NOT EXISTS (SELECT 1 FROM json_each(categories) WHERE lower(value) = 'page'))
          )
        GROUP BY 1, 2
        ORDER BY 1 DESC, 2 DESC
        """,
        [project_id, is_page]
      )

    Enum.map(rows, fn [year, month, count] -> %{year: year, month: month, count: count} end)
  end

  defp base_available_tags(project_id, pages?) do
    is_page = if pages?, do: 1, else: 0

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT DISTINCT trim(je.value)
        FROM posts, json_each(posts.tags) je
        WHERE posts.project_id = ?1
          AND trim(je.value) != ''
          AND (
            (?2 = 1 AND EXISTS (SELECT 1 FROM json_each(posts.categories) WHERE lower(value) = 'page'))
            OR
            (?2 = 0 AND NOT EXISTS (SELECT 1 FROM json_each(posts.categories) WHERE lower(value) = 'page'))
          )
        ORDER BY lower(trim(je.value))
        """,
        [project_id, is_page]
      )

    Enum.map(rows, fn [tag] -> tag end)
  end

  defp base_available_categories(project_id, pages?) do
    is_page = if pages?, do: 1, else: 0

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT DISTINCT trim(je.value)
        FROM posts, json_each(posts.categories) je
        WHERE posts.project_id = ?1
          AND trim(je.value) != ''
          AND lower(trim(je.value)) != 'page'
          AND (
            (?2 = 1 AND EXISTS (SELECT 1 FROM json_each(posts.categories) jc WHERE lower(jc.value) = 'page'))
            OR
            (?2 = 0 AND NOT EXISTS (SELECT 1 FROM json_each(posts.categories) jc WHERE lower(jc.value) = 'page'))
          )
        ORDER BY lower(trim(je.value))
        """,
        [project_id, is_page]
      )

    Enum.map(rows, fn [category] -> category end)
  end

  # ---------------------------------------------------------------------------
  # Media view (SQL-level filtering)
  # ---------------------------------------------------------------------------

  defp media_view(project_id, params) do
    filters = normalize_filter_params(params)
    tag_colors = tag_color_map(project_id)

    year_months = media_year_month_counts(project_id)
    avail_tags = media_available_tags(project_id)

    filtered_query = media_filtered_query(project_id, filters)
    total_count = Repo.one(from m in filtered_query, select: count(m.id))

    limited_media =
      Repo.all(
        from m in filtered_query,
          order_by: [desc: m.created_at],
          limit: ^filters.display_limit,
          select: %{
            id: m.id,
            title: m.title,
            original_name: m.original_name,
            mime_type: m.mime_type,
            size: m.size,
            tags: m.tags,
            alt: m.alt,
            caption: m.caption,
            updated_at: m.updated_at
          }
      )

    build_media_view(limited_media, filters, tag_colors, year_months, avail_tags, total_count)
  end

  defp build_media_view(
         limited_media,
         filters,
         tag_colors,
         year_month_counts,
         available_tags,
         total_count
       ) do
    loaded_count = length(limited_media)

    %{
      title: dgettext("ui", "Media"),
      subtitle: dgettext("ui", "Images and files"),
      layout: "media_grid",
      empty_message: dgettext("ui", "No media files"),
      filters: %{
        enabled: true,
        search_placeholder: dgettext("ui", "Search media..."),
        toggle_filters_label: dgettext("ui", "Toggle Filters"),
        archive_label: dgettext("render", "Archive"),
        tags_label: dgettext("ui", "Tags"),
        clear_tags_label: dgettext("ui", "Clear tags"),
        clear_filters_label: dgettext("ui", "Clear filters"),
        results_label: dgettext("ui", "results"),
        results_for_label: dgettext("ui", "results for"),
        no_results_label: dgettext("ui", "No media files"),
        year_month_counts: year_month_counts,
        available_tags: available_tags,
        available_tag_colors: Map.take(tag_colors, available_tags),
        available_categories: [],
        max_items: @default_page_size,
        display_limit: filters.display_limit,
        loaded_count: loaded_count,
        total_count: total_count,
        has_more: total_count > filters.display_limit,
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

  defp media_filtered_query(project_id, filters) do
    from(media in Media, where: media.project_id == ^project_id)
    |> maybe_where_media_search(filters.search)
    |> maybe_where_media_year(filters.year)
    |> maybe_where_media_month(filters.month)
    |> maybe_where_media_day(filters.day)
    |> maybe_where_all_media_tags(filters.tags)
  end

  defp maybe_where_media_search(query, nil), do: query

  defp maybe_where_media_search(query, search) do
    search_term = "%" <> String.downcase(search) <> "%"

    where(
      query,
      [m],
      fragment(
        """
        lower(COALESCE(?,'') || ' ' || COALESCE(?,'') || ' ' || COALESCE(?,'')
              || ' ' || COALESCE(?,'') || ' ' || COALESCE(?,'[]')) LIKE ?
        """,
        m.title,
        m.original_name,
        m.alt,
        m.caption,
        m.tags,
        ^search_term
      )
    )
  end

  defp maybe_where_media_year(query, nil), do: query

  defp maybe_where_media_year(query, year) do
    year_str = to_string(year)

    where(
      query,
      [m],
      fragment(
        "strftime('%Y', datetime(? / 1000, 'unixepoch')) = ?",
        m.updated_at,
        ^year_str
      )
    )
  end

  defp maybe_where_media_month(query, nil), do: query

  defp maybe_where_media_month(query, month) do
    month_str = String.pad_leading(to_string(month), 2, "0")

    where(
      query,
      [m],
      fragment(
        "strftime('%m', datetime(? / 1000, 'unixepoch')) = ?",
        m.updated_at,
        ^month_str
      )
    )
  end

  defp maybe_where_media_day(query, nil), do: query

  defp maybe_where_media_day(query, day) do
    day_str = String.pad_leading(to_string(day), 2, "0")

    where(
      query,
      [m],
      fragment(
        "strftime('%d', datetime(? / 1000, 'unixepoch')) = ?",
        m.updated_at,
        ^day_str
      )
    )
  end

  defp maybe_where_all_media_tags(query, []), do: query

  defp maybe_where_all_media_tags(query, tags),
    do: where_all_in_json_array(query, tags, :tags)

  defp where_all_in_json_array(query, items, field_atom, exclude_page? \\ false) do
    Enum.reduce(items, query, fn item, q ->
      if exclude_page? do
        where(
          q,
          [x],
          fragment(
            "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = lower(?) AND lower(value) != 'page')",
            field(x, ^field_atom),
            ^item
          )
        )
      else
        where(
          q,
          [x],
          fragment(
            "EXISTS (SELECT 1 FROM json_each(?) WHERE lower(value) = lower(?))",
            field(x, ^field_atom),
            ^item
          )
        )
      end
    end)
  end

  defp media_year_month_counts(project_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT CAST(strftime('%Y', datetime(updated_at / 1000, 'unixepoch')) AS INTEGER),
               CAST(strftime('%m', datetime(updated_at / 1000, 'unixepoch')) AS INTEGER),
               COUNT(*)
        FROM media
        WHERE project_id = ?1
          AND updated_at IS NOT NULL
        GROUP BY 1, 2
        ORDER BY 1 DESC, 2 DESC
        """,
        [project_id]
      )

    Enum.map(rows, fn [year, month, count] -> %{year: year, month: month, count: count} end)
  end

  defp media_available_tags(project_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT DISTINCT trim(je.value)
        FROM media, json_each(media.tags) je
        WHERE media.project_id = ?1
          AND trim(je.value) != ''
        ORDER BY lower(trim(je.value))
        """,
        [project_id]
      )

    Enum.map(rows, fn [tag] -> tag end)
  end

  # ---------------------------------------------------------------------------
  # Navigation views
  # ---------------------------------------------------------------------------

  defp tags_nav_view(count) do
    %{
      title: dgettext("ui", "Tags"),
      subtitle: dgettext("ui", "Tag management"),
      layout: "nav_list",
      items: [
        %{id: "tags-cloud", title: dgettext("ui", "Tag Cloud"), icon: "☁️", route: "tags"},
        %{id: "tags-manage", title: dgettext("ui", "Create / Edit"), icon: "✏️", route: "tags"},
        %{id: "tags-merge", title: dgettext("ui", "Merge Tags"), icon: "🔀", route: "tags"}
      ],
      summary_badge: count
    }
  end

  defp settings_nav_view do
    %{
      title: dgettext("ui", "Settings"),
      subtitle: dgettext("ui", "Project and publishing"),
      layout: "nav_list",
      items: [
        %{id: "settings-project", title: dgettext("ui", "Project"), icon: "📁", route: "settings"},
        %{id: "settings-editor", title: dgettext("ui", "Editor"), icon: "📝", route: "settings"},
        %{id: "settings-content", title: dgettext("ui", "Content"), icon: "📋", route: "settings"},
        %{id: "settings-ai", title: dgettext("ui", "AI"), icon: "🤖", route: "settings"},
        %{
          id: "settings-technology",
          title: dgettext("ui", "Technology"),
          icon: "⚙️",
          route: "settings"
        },
        %{
          id: "settings-publishing",
          title: dgettext("ui", "Publishing"),
          icon: "🚀",
          route: "settings"
        },
        %{id: "settings-data", title: dgettext("ui", "Data"), icon: "🗄️", route: "settings"},
        %{id: "settings-mcp", title: dgettext("ui", "MCP"), icon: "🔌", route: "settings"},
        %{id: "settings-style", title: dgettext("ui", "Style"), icon: "🎨", route: "style"}
      ]
    }
  end

  @git_history_page_size 20

  defp git_view(project_id) do
    base = %{
      title: dgettext("ui", "Git"),
      subtitle: dgettext("ui", "Working tree and history"),
      layout: "git",
      empty_message: dgettext("ui", "No items")
    }

    if git_repo?(project_id) do
      Map.merge(base, active_git_view(project_id))
    else
      Map.merge(base, %{git_state: "not_a_repo", remote_url: nil})
    end
  end

  defp git_repo?(nil), do: false

  defp git_repo?(project_id) when is_binary(project_id) do
    case BDS.Projects.get_project(project_id) do
      nil -> false
      project -> File.dir?(Path.join(BDS.Projects.project_data_dir(project), ".git"))
    end
  end

  defp active_git_view(project_id) do
    repo =
      case BDS.Git.repository(project_id) do
        {:ok, repo} -> repo
        _other -> %{current_branch: nil, remote_url: nil}
      end

    branch = repo[:current_branch]

    remote =
      case BDS.Git.remote_state(project_id) do
        {:ok, state} -> state
        _other -> %{upstream_branch: nil, ahead: 0, behind: 0}
      end

    status_files =
      case BDS.Git.status(project_id) do
        {:ok, %{files: files}} -> Enum.map(files, &git_status_file/1)
        _other -> []
      end

    commits =
      if is_binary(branch) do
        case BDS.Git.history(project_id, branch) do
          {:ok, %{commits: commits}} -> commits
          _other -> []
        end
      else
        []
      end

    %{
      git_state: "active",
      branch: branch,
      upstream: remote[:upstream_branch],
      ahead: remote[:ahead] || 0,
      behind: remote[:behind] || 0,
      status_files: status_files,
      history_entries:
        commits |> Enum.take(@git_history_page_size) |> Enum.map(&git_history_entry/1),
      has_more_history: length(commits) > @git_history_page_size,
      remote_url: repo[:remote_url]
    }
  end

  defp git_status_file(%{status: status} = file) do
    %{
      path: Map.get(file, :path, ""),
      status: to_string(status),
      code: git_status_code(status),
      label: git_status_label(status)
    }
  end

  defp git_status_code(:added), do: "A"
  defp git_status_code(:deleted), do: "D"
  defp git_status_code(:modified), do: "M"
  defp git_status_code(:renamed), do: "R"
  defp git_status_code(:untracked), do: "U"
  defp git_status_code(_other), do: "M"

  defp git_status_label(:added), do: dgettext("ui", "added")
  defp git_status_label(:deleted), do: dgettext("ui", "deleted")
  defp git_status_label(:modified), do: dgettext("ui", "modified")
  defp git_status_label(:renamed), do: dgettext("ui", "renamed")
  defp git_status_label(:untracked), do: dgettext("ui", "untracked")
  defp git_status_label(_other), do: dgettext("ui", "modified")

  defp git_history_entry(commit) do
    %{
      short_hash: commit |> Map.get(:hash, "") |> String.slice(0, 7),
      subject: Map.get(commit, :subject),
      author: Map.get(commit, :author),
      date: Map.get(commit, :date),
      sync_status: git_sync_status(get_in(commit, [:sync_status, :kind]))
    }
  end

  defp git_sync_status(:both), do: "synced"
  defp git_sync_status(:local_only), do: "local_only"
  defp git_sync_status(:remote_only), do: "remote_only"
  defp git_sync_status(_other), do: "synced"

  defp entity_list_view(title, subtitle, route, items) do
    %{
      title: title,
      subtitle: subtitle,
      layout: "entity_list",
      empty_message: dgettext("ui", "No items"),
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

  # ---------------------------------------------------------------------------
  # Post section builder
  # ---------------------------------------------------------------------------

  defp build_post_section(title, status, posts, translation_counts, published_meta?) do
    post_count = length(posts)

    %{
      id: Atom.to_string(status),
      title: title,
      status: Atom.to_string(status),
      count: post_count,
      items:
        Enum.map(posts, fn post ->
          %{
            id: post.id,
            title: display_post_title(post),
            categories: post.categories || [],
            tags: post.tags || [],
            status: Atom.to_string(post.status),
            language_count: 1 + Map.get(translation_counts, post.id, 0),
            meta_timestamp:
              if(published_meta?,
                do: post.published_at || post.updated_at,
                else: post.updated_at
              ),
            route: "post",
            search_blob: post_search_blob(post)
          }
        end)
    }
  end

  # ---------------------------------------------------------------------------
  # Data queries
  # ---------------------------------------------------------------------------

  defp translation_counts(project_id) do
    Repo.all(
      from translation in Translation,
        where: translation.project_id == ^project_id,
        group_by: translation.translation_for,
        select: {translation.translation_for, count(translation.id)}
    )
    |> Map.new()
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

  defp list_import_definitions(project_id) do
    ImportDefinitions.list_definitions(project_id)
  end

  defp tag_count(project_id) do
    Repo.one(from tag in Tag, where: tag.project_id == ^project_id, select: count(tag.id))
  end

  defp list_conversations do
    Repo.all(
      from conversation in ChatConversation,
        order_by: [desc: conversation.updated_at, desc: conversation.created_at],
        select: %{
          id: conversation.id,
          title: conversation.title,
          updated_at: conversation.updated_at
        }
    )
  end

  defp group_posts(posts) do
    grouped = Enum.group_by(posts, & &1.status)

    %{
      draft: Map.get(grouped, :draft, []),
      published: Map.get(grouped, :published, []),
      archived: Map.get(grouped, :archived, [])
    }
  end

  defp tag_color_map(project_id) do
    Repo.all(from tag in Tag, where: tag.project_id == ^project_id, select: {tag.name, tag.color})
    |> Enum.reduce(%{}, fn {name, color}, acc ->
      case String.trim(to_string(color || "")) do
        "" -> acc
        trimmed -> Map.put(acc, to_string(name), trimmed)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_view_id(view_id) when is_atom(view_id), do: Atom.to_string(view_id)
  defp normalize_view_id(view_id) when is_binary(view_id), do: view_id
  defp normalize_view_id(_other), do: ""

  defp normalize_filter_params(params) when is_map(params) do
    %{
      search: normalize_string(BDS.MapUtils.attr(params, :search)),
      year: normalize_integer(BDS.MapUtils.attr(params, :year)),
      month: normalize_integer(BDS.MapUtils.attr(params, :month)),
      day: normalize_integer(BDS.MapUtils.attr(params, :day)),
      tags: normalize_string_list(BDS.MapUtils.attr(params, :tags)),
      categories: normalize_string_list(BDS.MapUtils.attr(params, :categories)),
      display_limit:
        max(
          @default_page_size,
          normalize_integer(BDS.MapUtils.attr(params, :display_limit)) || @default_page_size
        )
    }
  end

  defp normalize_filter_params(_params), do: empty_filter_params()

  defp empty_filter_params do
    %{
      search: nil,
      year: nil,
      month: nil,
      day: nil,
      tags: [],
      categories: [],
      display_limit: @default_page_size
    }
  end

  defp filter_active?(filters) do
    present?(filters.search) or not is_nil(filters.year) or not is_nil(filters.day) or
      filters.tags != [] or filters.categories != []
  end

  defp post_search_blob(post) do
    [
      post.title,
      post.slug,
      post.excerpt,
      Enum.join(post.tags || [], " "),
      Enum.join(post.categories || [], " ")
    ]
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

  defp display_post_title(post) do
    cond do
      present?(post.title) -> post.title
      present?(post.slug) -> post.slug
      true -> dgettext("ui", "Untitled")
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

  defp present?(value), do: BDS.Values.present?(value)
end
