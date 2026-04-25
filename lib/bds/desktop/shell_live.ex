defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.Desktop.ShellData
  alias BDS.UI.Workbench

  @refresh_interval 1_500

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

  @impl true
  def handle_info(:refresh_task_status, socket) do
    task_status = BDS.Tasks.status_snapshot()

    {:noreply,
     socket
     |> assign(:task_status, task_status)
     |> assign(:editor_meta, ShellData.editor_meta(task_status))
     |> assign(:status, ShellData.status_bar(socket.assigns.workbench, task_status, socket.assigns.dashboard))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="app" id="bds-shell-app">
      <div class="window-titlebar" data-region="title-bar">
        <div class="window-titlebar-menu-bar is-hidden">
          <button class="window-titlebar-menu-button" type="button">File</button>
          <button class="window-titlebar-menu-button" type="button">Edit</button>
          <button class="window-titlebar-menu-button" type="button">View</button>
          <button class="window-titlebar-menu-button" type="button">Blog</button>
          <button class="window-titlebar-menu-button" type="button">Help</button>
        </div>
        <div class="window-titlebar-drag-region"></div>
        <div class="window-titlebar-title" data-testid="window-title"><%= @page_title %></div>
        <div class="window-titlebar-actions">
          <button
            class="window-titlebar-action-button"
            data-testid="toggle-sidebar"
            type="button"
            phx-click="toggle_sidebar"
            aria-label="Toggle sidebar"
            title="Toggle sidebar"
          >
            <span class={["window-titlebar-sidebar-icon", if(@workbench.sidebar_visible, do: "is-active", else: "is-inactive")]}>
              <span class="window-titlebar-sidebar-pane"></span>
            </span>
          </button>
          <button
            class="window-titlebar-action-button"
            data-testid="toggle-panel"
            type="button"
            phx-click="toggle_panel"
            aria-label="Toggle panel"
            title="Toggle panel"
          >
            <span class={["window-titlebar-panel-icon", if(@workbench.panel.visible, do: "is-active", else: "is-inactive")]}>
              <span class="window-titlebar-panel-pane"></span>
            </span>
          </button>
          <button
            class="window-titlebar-action-button"
            data-testid="toggle-assistant"
            type="button"
            phx-click="toggle_assistant_sidebar"
            aria-label="Toggle assistant"
            title="Toggle assistant"
          >
            <span class={["window-titlebar-assistant-icon", if(@workbench.assistant_sidebar_visible, do: "is-active", else: "is-inactive")]}>
              <span class="window-titlebar-assistant-pane"></span>
            </span>
          </button>
        </div>
      </div>

      <div class="app-main">
        <aside class="activity-bar" data-region="activity-bar">
          <div class="activity-bar-top">
            <%= for button <- Enum.filter(@activity_buttons, &(&1.activity_group == :top)) do %>
              <button
                class={["activity-bar-item", if(button.active, do: "active")]}
                data-testid="activity-button"
                data-view={button.id}
                data-active={to_string(button.active)}
                type="button"
                phx-click="select_view"
                phx-value-view={button.id}
                title={activity_label(button.label)}
                aria-label={activity_label(button.label)}
              >
                <%= raw(ShellData.activity_icon(button.id)) %>
              </button>
            <% end %>
          </div>
          <div class="activity-bar-bottom">
            <%= for button <- Enum.filter(@activity_buttons, &(&1.activity_group == :bottom)) do %>
              <button
                class={["activity-bar-item", if(button.active, do: "active")]}
                data-testid="activity-button"
                data-view={button.id}
                data-active={to_string(button.active)}
                type="button"
                phx-click="select_view"
                phx-value-view={button.id}
                title={activity_label(button.label)}
                aria-label={activity_label(button.label)}
              >
                <%= raw(ShellData.activity_icon(button.id)) %>
              </button>
            <% end %>
          </div>
        </aside>

        <section
          class={["sidebar-shell", if(not @workbench.sidebar_visible, do: "is-hidden")]}
          data-testid="sidebar-shell"
          style={"width: #{@workbench.sidebar_width}px;"}
        >
          <div class="sidebar" data-region="sidebar">
            <div class="sidebar-content sidebar-body">
              <div class="sidebar-section">
                <div class="sidebar-section-header">
                  <span><%= String.upcase(sidebar_header_label(@sidebar_header)) %></span>
                </div>
              </div>
              <%= render_sidebar_body(assigns) %>
            </div>
          </div>
          <div class="resizable-panel-divider sidebar-divider" data-resize="sidebar" data-role="resize-handle"></div>
        </section>

        <main class="app-content" data-region="content">
          <div class="tab-bar" data-region="tab-bar"></div>
          <section class="editor-shell" data-region="editor">
            <div class="editor-empty">
              <div class="dashboard-content">
                <h1 data-testid="editor-title"><%= translated("dashboard.title") %></h1>
                <p class="text-muted"><%= translated("dashboard.subtitle") %></p>

                <div class="dashboard-stats">
                  <div class="stat-card">
                    <div class="stat-number"><%= @dashboard.post_stats.total_posts || 0 %></div>
                    <div class="stat-label"><%= translated("dashboard.stats.totalPosts") %></div>
                    <div class="stat-breakdown">
                      <span class="stat-tag stat-published"><%= translated("dashboard.stats.published", %{count: @dashboard.post_stats.published_count || 0}) %></span>
                      <span class="stat-tag stat-draft"><%= translated("dashboard.stats.drafts", %{count: @dashboard.post_stats.draft_count || 0}) %></span>
                      <%= if (@dashboard.post_stats.archived_count || 0) > 0 do %>
                        <span class="stat-tag stat-archived"><%= translated("dashboard.stats.archived", %{count: @dashboard.post_stats.archived_count || 0}) %></span>
                      <% end %>
                    </div>
                  </div>
                  <div class="stat-card">
                    <div class="stat-number"><%= @dashboard.media_stats.media_count || 0 %></div>
                    <div class="stat-label"><%= translated("dashboard.stats.mediaFiles") %></div>
                    <div class="stat-breakdown">
                      <span class="stat-tag"><%= translated("dashboard.stats.images", %{count: @dashboard.media_stats.image_count || 0}) %></span>
                      <span class="stat-tag"><%= ShellData.format_bytes(@dashboard.media_stats.total_bytes || 0) %></span>
                    </div>
                  </div>
                  <div class="stat-card">
                    <div class="stat-number"><%= length(@dashboard.tag_cloud_items || []) %></div>
                    <div class="stat-label"><%= translated("dashboard.stats.tags") %></div>
                    <div class="stat-breakdown">
                      <span class="stat-tag"><%= translated("dashboard.stats.categories", %{count: length(@dashboard.category_counts || [])}) %></span>
                    </div>
                  </div>
                </div>

                <%= if Enum.any?(@dashboard.timeline_entries || []) do %>
                  <div class="dashboard-section">
                    <h4><%= translated("dashboard.section.postsOverTime") %></h4>
                    <div class="timeline-chart">
                      <%= for entry <- @dashboard.timeline_entries || [] do %>
                        <div class="timeline-bar-container">
                          <div class="timeline-bar" style={"height: #{timeline_height(entry, @dashboard.timeline_entries || [])}%"}>
                            <span class="timeline-bar-count"><%= entry.count || 0 %></span>
                          </div>
                          <div class="timeline-bar-label">
                            <span class="timeline-bar-label-month"><%= ShellData.format_dashboard_month(entry.year, entry.month) %></span>
                            <span class="timeline-bar-label-year"><%= entry.year %></span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if Enum.any?(@dashboard_tag_cloud_items) do %>
                  <div class="dashboard-section">
                    <h4><%= translated("dashboard.section.tags") %></h4>
                    <div class="tag-cloud">
                      <%= for item <- @dashboard_tag_cloud_items do %>
                        <span class={["dashboard-tag", if(item.color, do: "has-color")]} style={ShellData.render_dashboard_tag_style(item)} title={ShellData.dashboard_post_count_label(item.count)}><%= item.tag %></span>
                      <% end %>
                      <%= if length(@dashboard.tag_cloud_items || []) > 40 do %>
                        <span class="text-muted tag-cloud-more"><%= translated("dashboard.tagCloud.more", %{count: length(@dashboard.tag_cloud_items) - 40}) %></span>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if Enum.any?(@dashboard.category_counts || []) do %>
                  <div class="dashboard-section">
                    <h4><%= translated("dashboard.section.categories") %></h4>
                    <div class="tag-cloud">
                      <%= for category <- @dashboard.category_counts || [] do %>
                        <span class="dashboard-tag dashboard-category" title={ShellData.dashboard_post_count_label(category.count || 0)}>
                          <%= category.category || "" %>
                          <span class="tag-count"><%= category.count || 0 %></span>
                        </span>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if Enum.any?(@dashboard.recent_posts || []) do %>
                  <div class="dashboard-section">
                    <h4><%= translated("dashboard.section.recentlyUpdated") %></h4>
                    <div class="recent-posts-list">
                      <%= for post <- @dashboard.recent_posts || [] do %>
                        <button class="recent-post-item" type="button">
                          <span class="recent-post-title"><%= post.title || "" %></span>
                          <span class={"recent-post-status status-#{post.status || "draft"}"}><%= ShellData.dashboard_status_label(post.status || "draft") %></span>
                          <span class="recent-post-date"><%= ShellData.format_dashboard_date(post.updated_at) %></span>
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <div class="dashboard-inspector-meta" hidden>
                  <%= for item <- @editor_meta do %>
                    <section class="editor-meta-row">
                      <strong data-testid="editor-meta-label"><%= translated(item.label) %></strong>
                      <span><%= translated(item.value) %></span>
                    </section>
                  <% end %>
                </div>
              </div>
            </div>
          </section>

          <section class={["panel-shell", if(not @workbench.panel.visible, do: "is-hidden")]} data-region="panel">
            <div class="panel-header">
              <div class="panel-tabs">
                <%= for tab <- @panel_tabs do %>
                  <button
                    class={["panel-tab", if(@workbench.panel.active_tab == tab, do: "active")]}
                    type="button"
                    phx-click="select_panel_tab"
                    phx-value-tab={tab}
                  >
                    <%= panel_tab_label(tab) %>
                  </button>
                <% end %>
              </div>
            </div>
            <div class="panel-content">
              <%= render_panel_body(assigns) %>
            </div>
          </section>
        </main>

        <section
          class={["assistant-sidebar-shell", if(not @workbench.assistant_sidebar_visible, do: "is-hidden")]}
          data-testid="assistant-shell"
          style={"width: #{@workbench.assistant_sidebar_width}px;"}
        >
          <div class="resizable-panel-divider assistant-divider" data-resize="assistant" data-role="resize-handle"></div>
          <aside class="assistant-sidebar" data-region="assistant-sidebar">
            <div class="assistant-header">
              <strong><%= translated("Assistant") %></strong>
            </div>
            <div class="assistant-content">
              <%= for card <- @assistant_cards do %>
                <section class="assistant-card">
                  <strong><%= translated(card.label) %></strong>
                  <span><%= translated(card.text) %></span>
                </section>
              <% end %>
            </div>
          </aside>
        </section>
      </div>

      <footer class="status-bar" data-region="status-bar">
        <div class="status-bar-left">
          <div class="project-selector">
            <button class="project-selector-trigger" type="button" title={translated("Switch project")}>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" class="project-icon">
                <path d="M14.5 3H7.71l-.85-.85A.5.5 0 0 0 6.5 2h-5a.5.5 0 0 0-.5.5v11a.5.5 0 0 0 .5.5h13a.5.5 0 0 0 .5-.5v-10a.5.5 0 0 0-.5-.5zm-13 1h5.29l.85.85c.1.1.23.15.36.15h6.5v9h-13V4z"></path>
              </svg>
              <span class="project-name"><%= @current_project && @current_project.name || "My Blog" %></span>
              <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" class="dropdown-arrow">
                <path d="M4.5 5.5L8 9l3.5-3.5h-7z"></path>
              </svg>
            </button>
          </div>
          <button class="status-bar-item status-bar-task-button" type="button" phx-click="toggle_panel">
            <span><%= @status.left.running_task_message || translated("Idle") %></span>
            <%= if (@status.left.running_task_overflow || 0) > 0 do %>
              <span class="status-bar-count">+<%= @status.left.running_task_overflow %></span>
            <% end %>
          </button>
        </div>
        <div class="status-bar-right">
          <span class="status-bar-item"><%= @status.right.post_count %></span>
          <span class="status-bar-item"><%= @status.right.media_count %></span>
          <span class="status-bar-item theme-badge"><%= @status.right.theme_badge %></span>
          <button class={["status-bar-item", "offline-badge", if(@status.right.offline_mode, do: "active")]} type="button" title={translated("Toggle offline mode")}>✈</button>
          <label class="status-bar-item language-badge">
            <span><%= translated("UI") %></span>
            <select class="status-bar-language-select">
              <%= for language <- @supported_ui_languages do %>
                <option selected={language.code == @page_language} value={language.code}><%= language.flag %></option>
              <% end %>
            </select>
          </label>
          <span class="status-bar-item brand"><%= @status.right.brand %></span>
        </div>
      </footer>
    </div>
    """
  end

  defp reload_shell(socket, workbench) do
    projects = ShellData.project_snapshot()
    dashboard = ShellData.dashboard(projects.active_project_id)
    sidebar_data = ShellData.sidebar_view(projects.active_project_id, Atom.to_string(workbench.active_view))
    task_status = BDS.Tasks.status_snapshot()
    activity_buttons = Workbench.activity_buttons(workbench, 0)

    socket
    |> assign(:workbench, workbench)
    |> assign(:projects, projects)
    |> assign(:current_project, ShellData.current_project(projects))
    |> assign(:dashboard, dashboard)
    |> assign(:dashboard_tag_cloud_items, ShellData.dashboard_tag_cloud_items(dashboard.tag_cloud_items || []))
    |> assign(:sidebar_data, sidebar_data)
    |> assign(:sidebar_header, active_sidebar_label(activity_buttons, workbench.active_view, sidebar_data))
    |> assign(:assistant_cards, ShellData.assistant_cards())
    |> assign(:editor_meta, ShellData.editor_meta(task_status))
    |> assign(:task_status, task_status)
    |> assign(:status, ShellData.status_bar(workbench, task_status, dashboard))
    |> assign(:activity_buttons, activity_buttons)
    |> assign(:panel_tabs, ShellData.panel_tabs(workbench))
    |> assign(:supported_ui_languages, ShellData.supported_ui_languages())
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
    <%= for section <- @sidebar_data.sections || [] do %>
      <section class="sidebar-section">
        <div class="sidebar-section-title">
          <span class={"section-icon status-#{section.status || "draft"}"}>●</span>
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
          <span class="sidebar-section-count"><%= section.count || length(section.items || []) %></span>
        </div>
        <div class="sidebar-list">
          <%= for item <- section.items || [] do %>
            <button class="sidebar-item sidebar-post-item post-type-post" type="button">
              <span class="post-type-icon" title="post">●</span>
              <span class="sidebar-item-content">
                <span class="sidebar-item-title-row">
                  <span class="sidebar-item-title"><%= item.title || "" %></span>
                </span>
                <span class="sidebar-item-meta"><%= format_sidebar_timestamp(item.meta_timestamp) %></span>
              </span>
            </button>
          <% end %>
        </div>
      </section>
    <% end %>
    <%= if Enum.empty?(@sidebar_data.sections || []) do %>
      <div class="sidebar-empty">
        <p><%= translated(@sidebar_data.empty_message || "No items") %></p>
      </div>
    <% end %>
    """
  end

  defp render_media_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(@sidebar_data.items || []) do %>
      <div class="sidebar-list media-grid">
        <%= for item <- @sidebar_data.items || [] do %>
          <button class="media-item" type="button" title={item.title || ""}>
            <span class={media_thumbnail_class(item)}>
              <%= if image_media?(item) do %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
                <img class="media-thumbnail-image" src={"/media-thumbnail/#{item.id}"} alt="" loading="lazy" decoding="async" />
              <% else %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
              <% end %>
            </span>
            <span class="media-item-info">
              <span class="media-item-name"><%= item.title || "" %></span>
              <span class="media-item-size"><%= item.meta || "" %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(@sidebar_data.empty_message || "No items") %></p>
      </div>
    <% end %>
    """
  end

  defp render_entity_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(@sidebar_data.items || []) do %>
      <div class="settings-nav-list">
        <%= for item <- @sidebar_data.items || [] do %>
          <button class="chat-list-item" type="button">
            <span class="chat-item-content">
              <span class="chat-item-title"><%= item.title || "" %></span>
              <span class="chat-item-date"><%= translated(item.meta || "") %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(@sidebar_data.empty_message || "No items") %></p>
      </div>
    <% end %>
    """
  end

  defp render_nav_sidebar(assigns) do
    ~H"""
    <div class="settings-nav-list">
      <%= for item <- @sidebar_data.items || [] do %>
        <button class="settings-nav-entry" type="button">
          <span class="settings-nav-entry-icon"><%= item.icon || "" %></span>
          <span><%= translated(item.title || "") %></span>
        </button>
      <% end %>
    </div>
    """
  end

  defp render_default_sidebar(assigns) do
    ~H"""
    <%= for section <- @sidebar_data.sections || [] do %>
      <section class="sidebar-section">
        <div class="sidebar-section-header">
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
        </div>
        <div class="sidebar-section-items">
          <%= for item <- section.items || [] do %>
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
    <%= if Enum.empty?(@task_status.tasks || []) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Tasks") %></strong>
        <span><%= translated("No background tasks running") %></span>
      </div>
    <% else %>
      <div class="task-list">
        <%= for task <- @task_status.tasks || [] do %>
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
    Enum.find_value(activity_buttons, translated(sidebar_data.title || ""), fn button ->
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
