defmodule BDS.Desktop.ShellLive.ContentState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.AI
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.{SidebarState, SocketState, TabHelpers, TaskLocalization, TitlebarMenu}

  def refresh_content(socket, workbench) do
    projects =
      case ShellData.project_snapshot() do
        {:ok, data} -> data
        {:error, :not_ready} -> ShellData.default_project_snapshot()
      end

    dashboard =
      case ShellData.dashboard(projects.active_project_id) do
        {:ok, data} -> data
        {:error, :not_ready} -> BDS.UI.Dashboard.empty_snapshot()
      end

    git_badge_count =
      case ShellData.git_badge_count(projects.active_project_id) do
        {:ok, count} -> count
        {:error, :not_ready} -> 0
      end

    active_view_id = Atom.to_string(workbench.active_view)

    sidebar_data =
      case ShellData.sidebar_view(
             projects.active_project_id,
             active_view_id,
             SidebarState.current_filters(socket, active_view_id)
           ) do
        {:ok, data} -> data
        {:error, :not_ready} -> BDS.UI.Sidebar.view(nil, active_view_id, %{})
      end

    sidebar_data = SidebarState.merge_ui_state(socket, active_view_id, sidebar_data)

    socket
    |> assign(:projects, projects)
    |> assign(:current_project, ShellData.current_project(projects))
    |> assign(:dashboard, dashboard)
    |> assign(:dashboard_timeline_entries, Map.get(dashboard, :timeline_entries, []))
    |> assign(:dashboard_category_counts, Map.get(dashboard, :category_counts, []))
    |> assign(:dashboard_recent_posts, Map.get(dashboard, :recent_posts, []))
    |> assign(
      :dashboard_tag_cloud_items,
      ShellData.dashboard_tag_cloud_items(Map.get(dashboard, :tag_cloud_items, []))
    )
    |> assign(:git_badge_count, git_badge_count)
    |> assign(:sidebar_data, sidebar_data)
    |> SocketState.refresh_layout(workbench)
  end

  def reload_shell(socket, workbench) do
    tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})
    raw_task_status = BDS.Tasks.status_snapshot()
    page_language = socket.assigns[:page_language] || ShellData.ui_language()

    offline_mode =
      if Phoenix.LiveView.connected?(socket) do
        Map.get(socket.assigns, :offline_mode, AI.airplane_mode?(true))
      else
        Map.get(socket.assigns, :offline_mode, true)
      end

    task_status = TaskLocalization.localize_task_status(raw_task_status, page_language)

    socket
    |> assign(:tab_meta, tab_meta)
    |> assign(:task_status, task_status)
    |> assign(:offline_mode, offline_mode)
    |> assign(:supported_ui_languages, ShellData.supported_ui_languages())
    |> assign(:menu_groups, socket.assigns[:menu_groups] || TitlebarMenu.groups())
    |> assign(:titlebar_menu_item_index, socket.assigns[:titlebar_menu_item_index])
    |> refresh_content(workbench)
  end
end
