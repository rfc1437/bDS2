defmodule BDS.Desktop.ShellLive.SocketState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.{PanelRenderer, SidebarState}
  alias BDS.UI.Workbench

  use Gettext, backend: BDS.Gettext

  @output_entry_limit 20

  def refresh_layout(socket, workbench) do
    git_badge_count = socket.assigns[:git_badge_count] || 0
    activity_buttons = Workbench.activity_buttons(workbench, git_badge_count)

    task_status =
      socket.assigns[:task_status] || %{running_task_message: nil, running_task_overflow: nil}

    dashboard = socket.assigns[:dashboard] || BDS.UI.Dashboard.empty_snapshot()
    page_language = socket.assigns[:page_language] || ShellData.ui_language()
    offline_mode = Map.get(socket.assigns, :offline_mode, true)
    sidebar_data = socket.assigns[:sidebar_data] || %{}
    current_tab = current_tab(workbench)
    prev_tab = socket.assigns[:current_tab]

    prev_panel_tab =
      case socket.assigns[:workbench] do
        %Workbench{panel: %{active_tab: tab}} -> tab
        _ -> nil
      end

    socket =
      socket
      |> assign(:workbench, workbench)
      |> assign(:activity_buttons, activity_buttons)
      |> assign(:sidebar_header, active_sidebar_label(activity_buttons, workbench.active_view, sidebar_data))
      |> assign(:panel_tabs, ShellData.panel_tabs(workbench))
      |> assign(:current_tab, current_tab)
      |> assign(:editor_meta, ShellData.editor_meta(task_status))
      |> assign(
        :status,
        ShellData.status_bar(workbench, task_status, dashboard,
          ui_language: page_language,
          offline_mode: offline_mode
        )
      )

    if panel_data_stale?(current_tab, prev_tab, workbench.panel.active_tab, prev_panel_tab) do
      refresh_panel_data(socket)
    else
      socket
    end
  end

  def refresh_sidebar(socket, workbench) do
    project_id = (socket.assigns[:projects] || %{})[:active_project_id]
    active_view_id = Atom.to_string(workbench.active_view)

    sidebar_data =
      case ShellData.sidebar_view(
             project_id,
             active_view_id,
             SidebarState.current_filters(socket, active_view_id)
           ) do
        {:ok, data} -> data
        {:error, :not_ready} -> BDS.UI.Sidebar.view(nil, active_view_id, %{})
      end

    sidebar_data = SidebarState.merge_ui_state(socket, active_view_id, sidebar_data)

    socket
    |> assign(:sidebar_data, sidebar_data)
    |> refresh_layout(workbench)
  end

  def append_output_entry(socket, title, message, details \\ nil, level \\ "info") do
    entry = %{title: title, message: message, details: details, level: level}
    entries = [entry | socket.assigns.output_entries] |> Enum.take(@output_entry_limit)
    assign(socket, :output_entries, entries)
  end

  defp panel_data_stale?(current_tab, prev_tab, panel_tab, prev_panel_tab) do
    current_tab != prev_tab or panel_tab != prev_panel_tab
  end

  defp refresh_panel_data(socket) do
    panel_tab = socket.assigns.workbench.panel.active_tab

    socket
    |> assign(
      :panel_post_links,
      if(panel_tab == :post_links,
        do: PanelRenderer.fetch_post_link_entries(socket.assigns),
        else: socket.assigns[:panel_post_links] || %{backlinks: [], outlinks: []}
      )
    )
    |> assign(
      :panel_git_entries,
      if(panel_tab == :git_log,
        do: PanelRenderer.fetch_git_log_entries(socket.assigns),
        else: socket.assigns[:panel_git_entries] || []
      )
    )
  end

  defp activity_label("AI Assistant"), do: dgettext("ui", "Chat")
  defp activity_label("Source Control"), do: dgettext("ui", "Git")
  defp activity_label(label), do: label

  defp active_sidebar_label(activity_buttons, active_view, sidebar_data) do
    Enum.find_value(activity_buttons, Map.get(sidebar_data, :title, ""), fn button ->
      if button.id == active_view, do: activity_label(button.label), else: nil
    end)
  end

  defp current_tab(%{active_tab: nil}), do: nil

  defp current_tab(%{tabs: tabs, active_tab: {type, id}}) do
    Enum.find(tabs, &(&1.type == type and &1.id == id))
  end
end
