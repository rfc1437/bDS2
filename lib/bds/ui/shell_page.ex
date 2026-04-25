defmodule BDS.UI.ShellPage do
  @moduledoc false

  alias BDS.I18n
  alias BDS.Projects
  alias BDS.UI.Dashboard
  alias BDS.UI.MenuBar
  alias BDS.UI.Registry
  alias BDS.UI.Sidebar
  alias BDS.UI.Session
  alias BDS.UI.Workbench

  def render do
    bootstrap = bootstrap()
    ui_language = get_in(bootstrap, [:i18n, :ui_language]) || "en"

    [
      "<!DOCTYPE html>",
      "<html lang=\"#{ui_language}\">",
      "<head>",
      "  <meta charset=\"utf-8\">",
      "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "  <title>Blogging Desktop Server</title>",
      "  <link rel=\"stylesheet\" href=\"/assets/app.css\">",
      "</head>",
      "<body>",
      "  <div class=\"app\" id=\"bds-shell-app\">",
      "    <div class=\"window-titlebar\" data-region=\"title-bar\"></div>",
      "    <div class=\"app-main\">",
      "      <aside class=\"activity-bar\" data-region=\"activity-bar\"></aside>",
      "      <section class=\"sidebar-shell\" data-testid=\"sidebar-shell\">",
      "        <div class=\"sidebar\" data-region=\"sidebar\"></div>",
      "        <div class=\"resizable-panel-divider sidebar-divider\" data-resize=\"sidebar\" data-role=\"resize-handle\"></div>",
      "      </section>",
      "      <main class=\"app-content\" data-region=\"content\">",
      "        <div class=\"tab-bar\" data-region=\"tab-bar\"></div>",
      "        <section class=\"editor-shell\" data-region=\"editor\"></section>",
      "        <section class=\"panel-shell\" data-region=\"panel\"></section>",
      "      </main>",
      "      <section class=\"assistant-sidebar-shell\" data-testid=\"assistant-shell\">",
      "        <div class=\"resizable-panel-divider assistant-divider\" data-resize=\"assistant\" data-role=\"resize-handle\"></div>",
      "        <aside class=\"assistant-sidebar\" data-region=\"assistant-sidebar\"></aside>",
      "      </section>",
      "    </div>",
      "    <footer class=\"status-bar\" data-region=\"status-bar\"></footer>",
      "  </div>",
      "  <script id=\"bds-shell-bootstrap\" type=\"application/json\">#{Jason.encode!(bootstrap)}</script>",
      "  <script src=\"/assets/app.js\"></script>",
      "</body>",
      "</html>"
    ]
    |> Enum.join("\n")
  end

  defp bootstrap do
    workbench = Workbench.new()
    task_status = BDS.Tasks.status_snapshot()
    ui_language = I18n.current_ui_locale()
    projects = project_snapshot()
    dashboard = dashboard_content(projects.active_project_id)

    %{
      title: Application.get_env(:bds, :desktop)[:title] || "Blogging Desktop Server",
      i18n: %{
        ui_language: ui_language,
        catalogs:
          Enum.into(I18n.supported_languages(), %{}, fn language ->
            {language.code, I18n.get_ui_translations(language.code)}
          end),
        supported_ui_languages:
          Enum.map(I18n.supported_languages(), fn language ->
            %{
              code: language.code,
              flag: I18n.flag(language.code)
            }
          end)
      },
      registry: %{
        sidebar_views: Enum.map(Registry.sidebar_views(), &encode_sidebar_view/1),
        editor_routes: Enum.map(Registry.editor_routes(), &encode_editor_route/1),
        default_sidebar_view: Atom.to_string(Registry.default_sidebar_view())
      },
      menu_groups: Enum.map(MenuBar.default_groups(), &encode_menu_group/1),
      projects: projects,
      session: Session.serialize(workbench),
      task_status: task_status,
      content: %{
        sidebar: sidebar_content(projects.active_project_id),
        dashboard: dashboard,
        assistant_cards: assistant_cards(),
        editor_meta: editor_meta(task_status)
      },
      status:
        Workbench.status_bar(workbench,
          post_count: dashboard.post_stats.total_posts,
          media_count: dashboard.media_stats.media_count,
          theme_badge: "desktop-shell",
          ui_language: ui_language,
          offline_mode: true,
          running_task_message: task_status.running_task_message,
          running_task_overflow: task_status.running_task_overflow,
          git_badge_count: 3
        )
    }
  end

  defp encode_sidebar_view(view) do
    %{
      id: Atom.to_string(view.id),
      label: normalize_view_label(view.id, view.label),
      activity_group: Atom.to_string(view.activity_group),
      editor_route: Atom.to_string(view.editor_route),
      entity_tab: Map.get(view, :entity_tab, false),
      singleton: Map.get(view, :singleton, false)
    }
  end

  defp project_snapshot do
    Projects.shell_snapshot()
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and not String.contains?(Exception.message(error), "no such table: projects") do
        reraise error, __STACKTRACE__
      end

      default_project_snapshot()
  end

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

  defp encode_editor_route(route) do
    %{
      id: Atom.to_string(route.id),
      singleton: route.singleton,
      entity_tab: route.entity_tab,
      title: route.title
    }
  end

  defp encode_menu_group(group) do
    %{
      id: Atom.to_string(group.id),
      label: humanize(group.id),
      items:
        group.items
        |> Enum.reject(&Map.get(&1, :separator, false))
        |> Enum.map(fn item ->
          %{id: Atom.to_string(item.id), label: humanize(item.id)}
        end)
    }
  end

  defp sidebar_content(project_id) do
    Sidebar.snapshot(project_id)
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      Sidebar.empty_snapshot()
  end

  defp dashboard_content(project_id) do
    Dashboard.snapshot(project_id)
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      Dashboard.empty_snapshot()
  end

  defp assistant_cards do
    [
      %{label: "Offline Gate", text: "Automatic AI actions stay gated by airplane mode."},
      %{label: "Filesystem Sync", text: "Metadata flush, diffing, and rebuild hooks still need editor wiring."},
      %{label: "Desktop Runtime", text: "The app window is now served from the Elixir shell renderer."}
    ]
  end

  defp editor_meta(task_status) do
    %{
      dashboard: [
        %{label: "Status", value: task_status.running_task_message || "Idle"},
        %{label: "Mode", value: "Offline"},
        %{label: "Main Language", value: "en"}
      ]
    }
  end

  defp normalize_view_label(:chat, _label), do: "Chat"
  defp normalize_view_label(:git, _label), do: "Git"
  defp normalize_view_label(_id, label), do: label

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
