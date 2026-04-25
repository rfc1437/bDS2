defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.Desktop.ShellData
  alias BDS.UI.Registry
  alias BDS.UI.Workbench

  @refresh_interval 1_500

  embed_templates "shell_live/*"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, :refresh_task_status)
    end

    workbench = Workbench.new()

    {:ok,
     socket
     |> assign(:page_title, ShellData.title())
     |> assign(:page_language, ShellData.ui_language())
     |> assign(:offline_mode, true)
     |> assign(:tab_meta, %{})
     |> reload_shell(workbench)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_sidebar(socket.assigns.workbench))}
  end

  def handle_event("toggle_panel", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_panel(socket.assigns.workbench))}
  end

  def handle_event("toggle_assistant_sidebar", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_assistant_sidebar(socket.assigns.workbench))}
  end

  def handle_event("select_view", %{"view" => view_id}, socket) do
    workbench = Workbench.click_activity(socket.assigns.workbench, String.to_existing_atom(view_id))
    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("select_panel_tab", %{"tab" => tab}, socket) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(String.to_existing_atom(tab))

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("open_sidebar_item", %{"route" => route, "id" => id} = params, socket) do
    route_atom = sidebar_route_atom(route)
    tab_id = tab_id_for_route(route_atom, id)

    workbench =
      Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, tab_intent(route_atom))

    tab_meta =
      Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{
        title: Map.get(params, "title", ""),
        subtitle: Map.get(params, "subtitle", "")
      })

    {:noreply,
     socket
     |> assign(:tab_meta, tab_meta)
     |> reload_shell(workbench)}
  end

  def handle_event("select_tab", %{"type" => type, "id" => id}, socket) do
    workbench =
      Workbench.open_tab(socket.assigns.workbench, String.to_existing_atom(type), id, :preview)

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("toggle_offline_mode", _params, socket) do
    socket = assign(socket, :offline_mode, not socket.assigns.offline_mode)
    {:noreply, reload_shell(socket, socket.assigns.workbench)}
  end

  @impl true
  def handle_info(:refresh_task_status, socket) do
    task_status = BDS.Tasks.status_snapshot()

    {:noreply,
     socket
     |> assign(:task_status, task_status)
     |> assign(:editor_meta, ShellData.editor_meta(task_status))
     |> assign(
       :status,
       ShellData.status_bar(socket.assigns.workbench, task_status, socket.assigns.dashboard,
         ui_language: socket.assigns.page_language,
         offline_mode: socket.assigns.offline_mode
       )
     )}
  end

  @impl true
  def render(assigns), do: index(assigns)

  defp reload_shell(socket, workbench) do
    projects = ShellData.project_snapshot()
    dashboard = ShellData.dashboard(projects.active_project_id)
    sidebar_data = ShellData.sidebar_view(projects.active_project_id, Atom.to_string(workbench.active_view))
    task_status = BDS.Tasks.status_snapshot()
    activity_buttons = Workbench.activity_buttons(workbench, 0)
    page_language = socket.assigns[:page_language] || ShellData.ui_language()
    offline_mode = Map.get(socket.assigns, :offline_mode, true)

    socket
    |> assign(:workbench, workbench)
    |> assign(:projects, projects)
    |> assign(:current_project, ShellData.current_project(projects))
    |> assign(:dashboard, dashboard)
    |> assign(:dashboard_timeline_entries, Map.get(dashboard, :timeline_entries, []))
    |> assign(:dashboard_category_counts, Map.get(dashboard, :category_counts, []))
    |> assign(:dashboard_recent_posts, Map.get(dashboard, :recent_posts, []))
    |> assign(:dashboard_tag_cloud_items, ShellData.dashboard_tag_cloud_items(Map.get(dashboard, :tag_cloud_items, [])))
    |> assign(:sidebar_data, sidebar_data)
    |> assign(:sidebar_header, active_sidebar_label(activity_buttons, workbench.active_view, sidebar_data))
    |> assign(:assistant_cards, ShellData.assistant_cards())
    |> assign(:editor_meta, ShellData.editor_meta(task_status))
    |> assign(:task_status, task_status)
    |> assign(
      :status,
      ShellData.status_bar(workbench, task_status, dashboard,
        ui_language: page_language,
        offline_mode: offline_mode
      )
    )
    |> assign(:activity_buttons, activity_buttons)
    |> assign(:panel_tabs, ShellData.panel_tabs(workbench))
    |> assign(:supported_ui_languages, ShellData.supported_ui_languages())
    |> assign(:current_tab, current_tab(workbench))
  end

  defp render_sidebar_body(assigns) do
    case assigns.sidebar_data.layout do
      "post_list" -> render_post_sidebar(assigns)
      "media_grid" -> render_media_sidebar(assigns)
      "entity_list" -> render_entity_sidebar(assigns)
      "nav_list" -> render_nav_sidebar(assigns)
      _other -> render_default_sidebar(assigns)
    end
  end

  defp render_post_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-title">
          <span class={"section-icon status-#{Map.get(section, :status, "draft")}"}>●</span>
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
          <span class="sidebar-section-count"><%= Map.get(section, :count, length(Map.get(section, :items, []))) %></span>
        </div>
        <div class="sidebar-list">
          <%= for item <- Map.get(section, :items, []) do %>
            <button
              class={["sidebar-item", "sidebar-post-item", "post-type-post", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
              data-testid="sidebar-open-item"
              data-route={item.route}
              data-item-id={item.id}
              type="button"
              phx-click="open_sidebar_item"
              phx-value-route={item.route}
              phx-value-id={item.id}
              phx-value-title={item.title}
              phx-value-subtitle={format_sidebar_timestamp(item.meta_timestamp)}
            >
              <span class="post-type-icon" title="post">●</span>
              <span class="sidebar-item-content">
                <span class="sidebar-item-title-row">
                  <span class="sidebar-item-title"><%= item.title %></span>
                </span>
                <span class="sidebar-item-meta"><%= format_sidebar_timestamp(item.meta_timestamp) %></span>
              </span>
            </button>
          <% end %>
        </div>
      </section>
    <% end %>
    <%= if Enum.empty?(Map.get(@sidebar_data, :sections, [])) do %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_media_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class="sidebar-list media-grid">
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <button
            class={["media-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
            data-testid="sidebar-open-item"
            data-route={item.route}
            data-item-id={item.id}
            type="button"
            title={item.title}
            phx-click="open_sidebar_item"
            phx-value-route={item.route}
            phx-value-id={item.id}
            phx-value-title={item.title}
            phx-value-subtitle={item.meta}
          >
            <span class={media_thumbnail_class(item)}>
              <%= if image_media?(item) do %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
                <img class="media-thumbnail-image" src={"/media-thumbnail/#{item.id}"} alt="" loading="lazy" decoding="async" />
              <% else %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
              <% end %>
            </span>
            <span class="media-item-info">
              <span class="media-item-name"><%= item.title %></span>
              <span class="media-item-size"><%= item.meta %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_entity_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class="settings-nav-list">
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <button
            class={["chat-list-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "active")]}
            data-testid="sidebar-open-item"
            data-route={item.route}
            data-item-id={item.id}
            type="button"
            phx-click="open_sidebar_item"
            phx-value-route={item.route}
            phx-value-id={item.id}
            phx-value-title={item.title}
            phx-value-subtitle={translated(item.meta || "")}
          >
            <span class="chat-item-content">
              <span class="chat-item-title"><%= item.title %></span>
              <span class="chat-item-date"><%= translated(item.meta || "") %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_nav_sidebar(assigns) do
    ~H"""
    <div class="settings-nav-list">
      <%= for item <- Map.get(@sidebar_data, :items, []) do %>
        <button
          class="settings-nav-entry"
          data-testid="sidebar-open-item"
          data-route={item.route}
          data-item-id={item.id}
          type="button"
          phx-click="open_sidebar_item"
          phx-value-route={item.route}
          phx-value-id={item.id}
          phx-value-title={translated(item.title)}
          phx-value-subtitle={translated(Map.get(@sidebar_data, :subtitle, ""))}
        >
          <span class="settings-nav-entry-icon"><%= Map.get(item, :icon, "") %></span>
          <span><%= translated(item.title) %></span>
        </button>
      <% end %>
    </div>
    """
  end

  defp render_default_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-header">
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
        </div>
        <div class="sidebar-section-items">
          <%= for item <- Map.get(section, :items, []) do %>
            <div class="sidebar-list-item"><%= item.title || "" %></div>
          <% end %>
        </div>
      </section>
    <% end %>
    """
  end

  defp render_panel_body(assigns) do
    case assigns.workbench.panel.active_tab do
      :tasks -> render_task_entries(assigns)
      :output -> render_output_entries(assigns)
      :git_log -> render_git_log(assigns)
      other -> render_generic_panel(assigns, other)
    end
  end

  defp render_task_entries(assigns) do
    ~H"""
    <%= if Enum.empty?(Map.get(@task_status, :tasks, [])) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Tasks") %></strong>
        <span><%= translated("No background tasks running") %></span>
      </div>
    <% else %>
      <div class="task-list">
        <%= for task <- Map.get(@task_status, :tasks, []) do %>
          <div class="panel-entry task-entry">
            <div class="task-entry-header">
              <strong><%= task.name %></strong>
              <span class={"task-status task-status-#{task.status}"}><%= task.status |> to_string() |> String.capitalize() %></span>
            </div>
            <span><%= task.message || task.group_name || "" %></span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_output_entries(assigns) do
    ~H"""
    <div class="panel-entry panel-empty-state output-list">
      <strong><%= translated("Output") %></strong>
      <span><%= translated("No shell output yet") %></span>
    </div>
    """
  end

  defp render_git_log(assigns) do
    ~H"""
    <div class="git-log-list">
      <div class="panel-entry">
        <strong><%= translated("Git Log") %></strong>
        <span><%= translated("Working tree integration is not wired yet in the shell, but the tab is selectable and ready for command output.") %></span>
      </div>
    </div>
    """
  end

  defp render_generic_panel(assigns, tab) do
    assigns = assign(assigns, :panel_label, ShellData.route_label(tab))

    ~H"""
    <div class="panel-entry">
      <strong><%= @panel_label %></strong>
      <span><%= translated("The shared lower panel is available for tasks, output, git details, and editor-specific diagnostics.") %></span>
    </div>
    """
  end

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings)

  defp panel_tab_label(:tasks), do: translated("Tasks")
  defp panel_tab_label(:output), do: translated("Output")
  defp panel_tab_label(:git_log), do: translated("Git Log")
  defp panel_tab_label(tab), do: ShellData.route_label(tab)

  defp activity_label("AI Assistant"), do: "Chat"
  defp activity_label("Source Control"), do: "Git"
  defp activity_label(label), do: translated(label)

  defp active_sidebar_label(activity_buttons, active_view, sidebar_data) do
    Enum.find_value(activity_buttons, translated(Map.get(sidebar_data, :title, "")), fn button ->
      if button.id == active_view, do: activity_label(button.label), else: nil
    end)
  end

  defp sidebar_header_label(label), do: translated(label)

  defp timeline_height(entry, entries) do
    max_count =
      entries
      |> Enum.map(&(&1.count || 0))
      |> Enum.max(fn -> 1 end)

    max(4, ((entry.count || 0) / max_count) * 100)
  end

  defp format_sidebar_timestamp(nil), do: ""

  defp format_sidebar_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%x")
  end

  defp image_media?(item), do: String.starts_with?(to_string(item.mime_type || ""), "image/")

  defp media_thumbnail_class(item) do
    if image_media?(item), do: "media-thumbnail has-image", else: "media-thumbnail"
  end

  defp current_tab(%{active_tab: nil}), do: nil

  defp current_tab(%{tabs: tabs, active_tab: {type, id}}) do
    Enum.find(tabs, &(&1.type == type and &1.id == id))
  end

  defp sidebar_route_atom(route) when is_atom(route), do: route
  defp sidebar_route_atom(route) when is_binary(route), do: String.to_existing_atom(route)

  defp tab_id_for_route(route, id) do
    case Registry.editor_route(route) do
      %{singleton: true} -> Atom.to_string(route)
      _other -> id
    end
  end

  defp tab_intent(route) do
    case Registry.editor_route(route) do
      %{singleton: true} -> :pin
      _other -> :preview
    end
  end

  defp sidebar_item_selected?(workbench, route, id) do
    route_atom = sidebar_route_atom(route)
    workbench.active_tab == {route_atom, tab_id_for_route(route_atom, id)}
  end

  defp tab_title(nil, _tab_meta), do: translated("Dashboard")

  defp tab_title(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{title: title} when is_binary(title) and title != "" -> title
      _other -> default_tab_title(tab)
    end
  end

  defp tab_subtitle(nil, _tab_meta), do: translated("dashboard.subtitle")

  defp tab_subtitle(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{subtitle: subtitle} when is_binary(subtitle) and subtitle != "" -> subtitle
      _other -> "Desktop workbench content routed through the Elixir shell."
    end
  end

  defp default_tab_title(%{type: type, id: id}) do
    case Registry.editor_route(type) do
      %{singleton: true} -> ShellData.route_label(type)
      _other -> id
    end
  end

  defp tab_route_label(nil), do: translated("Dashboard")
  defp tab_route_label(%{type: type}), do: ShellData.route_label(type)

  defp tab_icon_id(nil), do: "posts"
  defp tab_icon_id(%{type: :post}), do: "posts"
  defp tab_icon_id(%{type: :git_diff}), do: "git"
  defp tab_icon_id(%{type: :style}), do: "settings"
  defp tab_icon_id(%{type: type}), do: Atom.to_string(type)

  defp media_thumbnail_glyph(mime_type) do
    case String.split(to_string(mime_type || ""), "/", parts: 2) do
      ["image", _rest] -> "IMG"
      ["video", _rest] -> "VID"
      ["audio", _rest] -> "AUD"
      ["application", _rest] -> "DOC"
      _other -> "FILE"
    end
  end
end
