defmodule BDS.UI.ShellTest do
  use ExUnit.Case, async: true

  alias BDS.UI.Commands
  alias BDS.UI.Registry
  alias BDS.UI.Session
  alias BDS.UI.ShellPage
  alias BDS.UI.Workbench

  test "registry exposes the shared sidebar and editor contracts for the base shell" do
    sidebar_views = Registry.sidebar_views()
    editor_routes = Registry.editor_routes()

    assert Registry.default_sidebar_view() == :posts
    assert Enum.map(sidebar_views, & &1.id) == [
             :posts,
             :pages,
             :media,
             :scripts,
             :templates,
             :tags,
             :chat,
             :import,
             :git,
             :settings
           ]

    assert Enum.find(sidebar_views, &(&1.id == :media)).activity_group == :top
    assert Enum.find(sidebar_views, &(&1.id == :git)).activity_group == :bottom
    assert Enum.any?(editor_routes, &(&1.id == :dashboard))
    assert Enum.any?(editor_routes, &(&1.id == :post and &1.entity_tab == true))
    assert Enum.any?(editor_routes, &(&1.id == :settings and &1.singleton == true))
  end

  test "workbench session roundtrips tabs, dirty state, shell visibility, and widths" do
    state =
      Workbench.new(sidebar_visible: false, panel_visible: true)
      |> Workbench.set_sidebar_width(412)
      |> Workbench.set_assistant_sidebar_width(511)
      |> Workbench.open_tab(:post, "post-1", :pin)
      |> Workbench.open_tab(:media, "media-1", :preview)
      |> Workbench.mark_dirty(:post, "post-1")
      |> Workbench.click_activity(:media)

    payload = Session.serialize(state)
    restored = Session.restore(payload)

    assert restored.sidebar_visible == true
    assert restored.panel.visible == true
    assert restored.sidebar_width == 412
    assert restored.assistant_sidebar_width == 511
    assert restored.active_view == :media
    assert restored.active_tab == {:media, "media-1"}
    assert Workbench.dirty?(restored, :post, "post-1") == true
    assert Enum.map(restored.tabs, &{&1.type, &1.id, &1.is_transient}) == [
             {:post, "post-1", false},
             {:media, "media-1", true}
           ]
  end

  test "keyboard commands drive the same shared workbench policy" do
    state =
      Workbench.new(sidebar_visible: true)
      |> Workbench.open_tab(:post, "post-1", :pin)

    state = Commands.handle_shortcut(state, %{meta: true, key: "b"})
    assert state.sidebar_visible == false

    state = Commands.handle_shortcut(state, %{meta: true, key: "j"})
    assert state.panel.visible == true

    state = Commands.handle_shortcut(state, %{meta: true, key: "1"})
    assert state.active_view == :posts

    state = Commands.handle_shortcut(state, %{meta: true, key: "2"})
    assert state.active_view == :media

    state = Commands.handle_shortcut(state, %{meta: true, key: "w"})
    assert state.tabs == []
    assert state.editor_route == :dashboard
  end

  test "resizing is clamped to the shell limits and dirty flags only apply to post tabs" do
    state =
      Workbench.new()
      |> Workbench.set_sidebar_width(999)
      |> Workbench.set_assistant_sidebar_width(120)
      |> Workbench.open_tab(:media, "media-1", :pin)
      |> Workbench.mark_dirty(:media, "media-1")
      |> Workbench.open_tab(:post, "post-1", :pin)
      |> Workbench.mark_dirty(:post, "post-1")

    assert state.sidebar_width == 500
    assert state.assistant_sidebar_width == 280
    assert Workbench.dirty?(state, :media, "media-1") == false
    assert Workbench.dirty?(state, :post, "post-1") == true
  end

  test "shell page renders the inspectable base app with bootstrap data and shell controls" do
    html = ShellPage.render()

    assert html =~ ~s(<div class="app" id="bds-shell-app")
    assert html =~ ~s(data-region="activity-bar")
    assert html =~ ~s(data-region="sidebar")
    assert html =~ ~s(data-region="editor")
    assert html =~ ~s(data-region="status-bar")
    assert html =~ ~s(data-role="resize-handle")
    assert html =~ ~s(id="bds-shell-bootstrap")
    assert html =~ ~s(src="/assets/app.js")
    assert html =~ ~s(href="/assets/app.css")
    assert html =~ ~s("task_status")
    assert html =~ ~s("flag":"🇩🇪")
    assert html =~ ~s("projects")
    assert html =~ ~s("id":"default")
    assert html =~ ~s("name":"My Blog")
  end

  test "shell page localizes bootstrap content for german ui locale" do
    previous_lang = System.get_env("LANG")
    previous_lc_all = System.get_env("LC_ALL")

    on_exit(fn ->
      restore_env("LANG", previous_lang)
      restore_env("LC_ALL", previous_lc_all)
    end)

    System.put_env("LANG", "de_DE.UTF-8")
    System.delete_env("LC_ALL")

    html = ShellPage.render()

    assert html =~ ~s("ui_language":"de")
    assert html =~ ~s("catalogs")
    assert html =~ ~s("File":"Datei")
    assert html =~ ~s("Dashboard":"Instrumententafel")
    assert html =~ ~s("Assistant":"Assistent")
  end

  test "shell bootstrap and static bundle expose the old dashboard sections" do
    html = ShellPage.render()
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert html =~ ~s("timeline_entries")
    assert html =~ ~s("tag_cloud_items")
    assert html =~ ~s("category_counts")
    assert html =~ ~s("recent_posts")

    assert js =~ "dashboard-content"
    assert js =~ "dashboard-stats"
    assert js =~ "timeline-chart"
    assert js =~ "tag-cloud"
    assert js =~ "recent-posts-list"

    assert css =~ ".dashboard-content"
    assert css =~ ".dashboard-stats"
    assert css =~ ".timeline-chart"
    assert css =~ ".tag-cloud"
    assert css =~ ".recent-posts-list"
  end

  test "shell bootstrap and static bundle expose the old sidebar view contracts" do
    html = ShellPage.render()
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert html =~ ~s("layout":"post_list")
    assert html =~ ~s("layout":"media_grid")
    assert html =~ ~s("layout":"entity_list")
    assert html =~ ~s("layout":"nav_list")

    assert js =~ "renderSidebarPostList"
    assert js =~ "renderSidebarMediaGrid"
    assert js =~ "renderSidebarEntityList"
    assert js =~ "renderSidebarNavList"

    assert css =~ ".sidebar-section-title"
    assert css =~ ".media-grid"
    assert css =~ ".chat-list-item"
    assert css =~ ".settings-nav-entry"
  end

  test "shell bootstrap and static bundle expose old sidebar filters and the post cutoff contract" do
    html = ShellPage.render()
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert html =~ ~s("filters")
    assert html =~ ~s("search_placeholder":"sidebar.searchPostsPlaceholder")
    assert html =~ ~s("search_placeholder":"sidebar.searchMediaPlaceholder")
    assert html =~ ~s("year_month_counts")
    assert html =~ ~s("available_tags")
    assert html =~ ~s("available_categories")
    assert html =~ ~s("max_items":500)

    assert js =~ "renderSidebarSearchBox"
    assert js =~ "renderSidebarArchiveFilter"
    assert js =~ "renderSidebarFilterPanel"
    assert js =~ "renderSidebarFilterStatus"
    assert js =~ "applySidebarPostFilters"
    assert js =~ "applySidebarMediaFilters"

    assert css =~ ".search-box"
    assert css =~ ".filter-panel"
    assert css =~ ".calendar-view"
    assert css =~ ".filter-chip"
    assert css =~ ".filter-status"
  end

  test "clearing sidebar filters resets from the baseline seed instead of the filtered payload" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "sidebarFilterSeeds"
    assert js =~ "function sidebarFilterSeed(viewId)"
    assert js =~ "defaultSidebarFilterState(viewId, sidebarFilterSeed(viewId))"
    refute js =~ "defaultSidebarFilterState(viewId, state.sidebarContent[viewId])"
  end

  test "static shell bundle exists for direct browser inspection" do
    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/index.html")
    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/app.css")
    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/app.js")
  end

  test "static shell bundle keeps the old compact frame metrics and icon-based controls" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert css =~ ".window-titlebar"
    assert css =~ "height: 34px"
    assert css =~ "width: 48px"
    assert css =~ "height: 35px"
    assert css =~ "height: 22px"

    assert js =~ "window-titlebar-sidebar-icon"
    assert js =~ "window-titlebar-panel-icon"
    assert js =~ "window-titlebar-assistant-icon"
    assert js =~ "toggle-assistant-sidebar"
    assert js =~ "activity-bar-top"
    assert js =~ "activity-bar-bottom"
  end

  test "static shell bundle hides the fake titlebar menu on macOS and keeps old status-bar alignment rules" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "navigator.platform"
    assert js =~ "isMac"
    assert js =~ "window-titlebar-menu-bar is-hidden"

    assert css =~ ".window-titlebar-menu-bar.is-hidden"
    assert css =~ "--vscode-statusBar-background: #007acc"
    assert css =~ ".status-bar-left,"
    assert css =~ "gap: 4px"
    assert css =~ "padding: 0 8px"
    assert css =~ "height: 100%"
    refute css =~ "background: var(--status)"
    assert css =~ ".status-bar-language-select"
    assert css =~ ".status-bar-item.language-badge"
    assert css =~ ".status-bar-item.offline-badge"

    assert js =~ "renderLanguageOptions"
    assert js =~ "language.flag || language.code.toUpperCase()"
    assert js =~ "status-bar-language-select"
    assert js =~ "setUiLanguage"
  end

  test "static shell bundle polls live task status and renders a task-backed lower panel" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "/api/tasks"
    assert js =~ "/api/projects"
    assert js =~ "/api/commands"
    assert js =~ "fetchTaskStatus"
    assert js =~ "executeBackendShellCommand"
    assert js =~ "applyShellCommandResult"
    assert js =~ "openTasksPanel"
    assert js =~ "command === \"open-tasks-panel\")"
    assert js =~ "openTasksPanel();"
    assert js =~ "return;"
    assert js =~ "No background tasks running"
    assert js =~ "task-list"
    assert js =~ "output-list"
    assert js =~ "git-log-list"
    assert js =~ "data-panel-tab=\"output\""
    assert js =~ "data-panel-tab=\"git_log\""
  end

  test "static shell bundle keeps bottom panel tabs in a stable order" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "return [\"tasks\", \"output\", \"git_log\", state.session.panel.active_tab].filter(uniqueValue);"
  end

  test "static shell bundle renders a left-side project field with selection, existing-folder import, and create affordances" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "project-selector-trigger"
    assert js =~ "project-dropdown"
    assert js =~ "create-project-btn"
    assert js =~ "existing-project-btn"
    assert js =~ "/api/project-folder"
    assert js =~ "fetchProjects"
    assert js =~ "createProject"
    assert js =~ "importExistingProject"
    assert js =~ "selectProject"
    assert js =~ "toggleProjectMenu"
    assert js =~ "closeProjectMenu"

    assert css =~ ".project-selector-trigger"
    assert css =~ ".project-dropdown"
    assert css =~ ".create-project-btn"
    assert css =~ ".existing-project-btn"
  end

  test "static shell bundle uses translation catalogs for visible shell chrome" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "translationsForLanguage"
    assert js =~ "function t("
    assert js =~ "New Project"
    assert js =~ "No background tasks running"
    assert js =~ "Idle"
  end

  test "static shell bundle binds base shell hotkeys and menu actions to existing shell functionality" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "window.addEventListener(\"keydown\""
    assert js =~ "event.metaKey"
    assert js =~ "case \"j\""
    assert js =~ "case \"1\""
    assert js =~ "case \"2\""
    assert js =~ "case \"\\\\\""
    assert js =~ "case \"view_posts\""
    assert js =~ "case \"view_media\""
    assert js =~ "executeBackendShellCommand(action)"
    assert js =~ "case \"metadata_diff\""
    assert js =~ "case \"regenerate_calendar\""
    assert js =~ "case \"fill_missing_translations\""
    assert js =~ "root.querySelectorAll(\"button[data-command]\")"
    assert js =~ "[data-close-tab]"
    assert js =~ "language.flag"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
