defmodule BDS.Desktop.ShellData do
  @moduledoc false

  alias BDS.Git
  alias BDS.I18n
  alias BDS.Projects
  alias BDS.UI.Dashboard
  alias BDS.UI.Sidebar
  alias BDS.UI.Workbench

  def title do
    Application.get_env(:bds, :desktop)[:title] || "Blogging Desktop Server"
  end

  def ui_language do
    I18n.current_ui_locale()
  end

  def translations(locale \\ nil) do
    I18n.get_ui_translations(effective_ui_language(locale))
  end

  def supported_ui_languages do
    Enum.map(I18n.supported_languages(), fn language ->
      %{code: language.code, flag: I18n.flag(language.code)}
    end)
  end

  def translate(key, bindings \\ %{}, locale \\ nil) do
    text = Map.get(translations(locale), to_string(key), to_string(key))

    Enum.reduce(bindings, text, fn {binding, value}, acc ->
      String.replace(acc, "%{#{binding}}", to_string(value))
    end)
  end

  def project_snapshot do
    Projects.shell_snapshot()
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and
           not String.contains?(Exception.message(error), "no such table: projects") do
        reraise error, __STACKTRACE__
      end

      default_project_snapshot()
  end

  def current_project(projects_snapshot) do
    Enum.find(projects_snapshot.projects, &(&1.id == projects_snapshot.active_project_id)) ||
      List.first(projects_snapshot.projects)
  end

  def dashboard(project_id) do
    Dashboard.snapshot(project_id)
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and
           not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      Dashboard.empty_snapshot()
  end

  def sidebar_view(project_id, view_id, params \\ %{}) do
    Sidebar.view(project_id, view_id, params)
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and
           not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      Sidebar.view(nil, view_id, params)
  end

  def assistant_cards do
    [
      %{label: "Offline Gate", text: "Automatic AI actions stay gated by airplane mode."},
      %{
        label: "Filesystem Sync",
        text: "Metadata flush, diffing, and rebuild hooks still need editor wiring."
      },
      %{label: "Desktop Runtime", text: "The app window is now served from LiveView state."}
    ]
  end

  def editor_meta(task_status) do
    [
      %{label: "Status", value: task_status.running_task_message || "Idle"},
      %{label: "Mode", value: "Offline"},
      %{label: "Main Language", value: ui_language()}
    ]
  end

  def status_bar(workbench, task_status, dashboard, opts \\ []) do
    Workbench.status_bar(workbench,
      post_count: dashboard.post_stats.total_posts,
      media_count: dashboard.media_stats.media_count,
      theme_badge: "desktop-shell",
      ui_language: Keyword.get(opts, :ui_language, ui_language()),
      offline_mode: Keyword.get(opts, :offline_mode, true),
      running_task_message: task_status.running_task_message,
      running_task_overflow: task_status.running_task_overflow,
      active_post_status: nil
    )
  end

  def git_badge_count(project_id, opts \\ [])

  def git_badge_count(nil, _opts), do: 0
  def git_badge_count("default", _opts), do: 0

  def git_badge_count(project_id, opts) when is_binary(project_id) do
    provider = Keyword.get(opts, :provider, git_remote_state_provider())

    try do
      case provider.(project_id, []) do
        {:ok, %{behind: behind}} when is_integer(behind) and behind > 0 -> behind
        {:ok, %{behind: behind}} when is_binary(behind) -> parse_positive_count(behind)
        _other -> 0
      end
    rescue
      error in [DBConnection.OwnershipError, Exqlite.Error] ->
        if match?(%Exqlite.Error{}, error) and
             not String.contains?(Exception.message(error), "no such table") do
          reraise error, __STACKTRACE__
        end

        0
    end
  end

  def panel_tabs(workbench) do
    [:tasks, :output]
    |> maybe_add_panel_tab(workbench.editor_route, :post_links)
    |> maybe_add_panel_tab(workbench.editor_route, :git_log)
    |> Kernel.++([workbench.panel.active_tab])
    |> Enum.uniq()
  end

  defp git_remote_state_provider do
    Application.get_env(:bds, :git_remote_state_provider, &Git.remote_state/2)
  end

  defp parse_positive_count(value) do
    case Integer.parse(value) do
      {count, _rest} when count > 0 -> count
      _other -> 0
    end
  end

  def activity_icon(id) do
    case to_string(id) do
      "posts" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zM6 20V4h7v5h5v11H6z"></path><path d="M8 12h8v2H8zm0 4h8v2H8z"></path></svg>)

      "pages" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h10v4h6v12H4V4zm10 1.5V9h4.5L14 5.5zM7 12h10v1.5H7V12zm0 3h10v1.5H7V15z"></path></svg>)

      "media" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"></path></svg>)

      "scripts" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M20 3H4a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h7v2H8v2h8v-2h-3v-2h7a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1zM5 14V5h14v9H5zm2-7.5L9.5 9 7 11.5l1.4 1.4L12.3 9 8.4 5.1 7 6.5zm6.5 5.5h4v-2h-4v2z"></path></svg>)

      "templates" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M4 4h7v7H4V4zm9 0h7v7h-7V4zM4 13h7v7H4v-7zm9 0h7v7h-7v-7zM5.5 5.5v4h4v-4h-4zm9 0v4h4v-4h-4zm-9 9v4h4v-4h-4zm9 0v4h4v-4h-4z"></path></svg>)

      "tags" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M21.41 11.58l-9-9C12.05 2.22 11.55 2 11 2H4c-1.1 0-2 .9-2 2v7c0 .55.22 1.05.59 1.42l9 9c.36.36.86.58 1.41.58s1.05-.22 1.41-.59l7-7c.37-.36.59-.86.59-1.41s-.23-1.06-.59-1.42zM5.5 7C4.67 7 4 6.33 4 5.5S4.67 4 5.5 4 7 4.67 7 5.5 6.33 7 5.5 7z"></path></svg>)

      "chat" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"></path><circle cx="8" cy="10" r="1.5"></circle><circle cx="12" cy="10" r="1.5"></circle><circle cx="16" cy="10" r="1.5"></circle></svg>)

      "import" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"></path></svg>)

      "git" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M22 11.73L12.27 2a1 1 0 0 0-1.41 0L8.84 4.02l2.56 2.56a1.2 1.2 0 0 1 1.52 1.53l2.47 2.47a1.2 1.2 0 1 1-.72.67l-2.3-2.3v6.06a1.2 1.2 0 1 1-.85 0V8.9a1.2 1.2 0 0 1-.66-1.59L8.35 4.8 2 11.16a1 1 0 0 0 0 1.41L11.73 22a1 1 0 0 0 1.41 0L22 13.14a1 1 0 0 0 0-1.41z"></path></svg>)

      "settings" ->
        ~s(<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19.14 12.94c.04-.31.06-.63.06-.94 0-.31-.02-.63-.06-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.04.31-.06.63-.06.94s.02.63.06.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"></path></svg>)

      _other ->
        activity_icon("posts")
    end
  end

  def dashboard_status_label(status) do
    case to_string(status) do
      "draft" -> translate("dashboard.status.draft")
      "published" -> translate("dashboard.status.published")
      "archived" -> translate("dashboard.status.archived")
      other -> other |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def dashboard_post_count_label(count) do
    normalized_count = count || 0

    key =
      if normalized_count == 1, do: "dashboard.postCount.one", else: "dashboard.postCount.other"

    translate(key, %{count: normalized_count})
  end

  def dashboard_tag_cloud_items(items) when is_list(items) do
    top_items =
      items
      |> Enum.sort_by(fn item -> -(item.count || 0) end)
      |> Enum.take(40)

    counts = Enum.map(top_items, &(&1.count || 0))
    max_count = Enum.max([1 | counts])
    min_count = Enum.min([max_count | counts])
    range = max(max_count - min_count, 1)

    top_items
    |> Enum.map(fn item ->
      font_size = 11 + ((item.count || 0) - min_count) / range * 11
      Map.merge(item, %{font_size: font_size, color: normalize_dashboard_tag_color(item.color)})
    end)
    |> Enum.sort_by(&String.downcase(to_string(&1.tag || "")))
  end

  def render_dashboard_tag_style(item) do
    declarations = ["font-size: #{Float.round(item.font_size || 11, 1)}px;"]

    declarations =
      if item.color do
        declarations ++
          [
            "background-color: #{item.color};",
            "color: #{dashboard_contrast_color(item.color)};"
          ]
      else
        declarations
      end

    Enum.join(declarations, " ")
  end

  def format_dashboard_month(year, month) do
    {:ok, date} = Date.new(year, month, 1)
    Calendar.strftime(date, "%b")
  end

  def format_dashboard_date(nil), do: ""

  def format_dashboard_date(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%x")
  end

  def route_label(route) do
    case to_string(route) do
      "git_log" ->
        "Git Log"

      "post_links" ->
        "Post Links"

      other ->
        other
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  def format_bytes(bytes) do
    normalized_bytes = max(bytes || 0, 0)

    cond do
      normalized_bytes == 0 ->
        "0 B"

      true ->
        units = ["B", "KB", "MB", "GB"]
        unit_index = min(trunc(:math.log(normalized_bytes) / :math.log(1024)), length(units) - 1)
        value = normalized_bytes / :math.pow(1024, unit_index)
        decimals = if value >= 10 or unit_index == 0, do: 0, else: 1
        unit = Enum.at(units, unit_index)
        :erlang.float_to_binary(value, decimals: decimals) <> " " <> unit
    end
  end

  defp effective_ui_language(nil) do
    BDS.Desktop.UILocale.current() || ui_language()
  end

  defp effective_ui_language(locale), do: locale

  defp maybe_add_panel_tab(tabs, :post, :post_links), do: tabs ++ [:post_links]

  defp maybe_add_panel_tab(tabs, route, :git_log) when route in [:post, :media],
    do: tabs ++ [:git_log]

  defp maybe_add_panel_tab(tabs, _route, _tab), do: tabs

  defp default_project_snapshot do
    %{
      active_project_id: "default",
      projects: [
        %{
          id: "default",
          name: "My Blog",
          slug: "my-blog",
          data_path: nil,
          is_active: true
        }
      ]
    }
  end

  defp normalize_dashboard_tag_color(nil), do: nil
  defp normalize_dashboard_tag_color(""), do: nil

  defp normalize_dashboard_tag_color("#" <> rest = color) when byte_size(rest) == 6 do
    if String.match?(rest, ~r/\A[0-9a-fA-F]{6}\z/), do: color, else: nil
  end

  defp normalize_dashboard_tag_color(_color), do: nil

  defp dashboard_contrast_color("#" <> rgb) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = rgb
    {red, _} = Integer.parse(r, 16)
    {green, _} = Integer.parse(g, 16)
    {blue, _} = Integer.parse(b, 16)
    luminance = (red * 299 + green * 587 + blue * 114) / 1000
    if luminance > 150, do: "#1e1e1e", else: "#ffffff"
  end

  defp dashboard_contrast_color(_color), do: "#ffffff"
end
