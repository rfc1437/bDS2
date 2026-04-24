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
    assert css =~ "--vscode-statusBar-background: #181818"
    assert css =~ ".status-bar-left,"
    assert css =~ "gap: 4px"
    assert css =~ "padding: 0 8px"
    assert css =~ "height: 100%"
    assert css =~ ".status-bar-language-select"
    assert css =~ ".status-bar-item.language-badge"
    assert css =~ ".status-bar-item.offline-badge"

    assert js =~ "renderLanguageOptions"
    assert js =~ "status-bar-language-select"
    assert js =~ "setUiLanguage"
  end

  test "static shell bundle polls live task status and renders a task-backed lower panel" do
    js = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.js")

    assert js =~ "/api/tasks"
    assert js =~ "/api/commands"
    assert js =~ "fetchTaskStatus"
    assert js =~ "executeBackendShellCommand"
    assert js =~ "applyShellCommandResult"
    assert js =~ "openTasksPanel"
    assert js =~ "No background tasks running"
    assert js =~ "task-list"
    assert js =~ "output-list"
    assert js =~ "git-log-list"
    assert js =~ "data-panel-tab=\"output\""
    assert js =~ "data-panel-tab=\"git_log\""
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
  end
end
