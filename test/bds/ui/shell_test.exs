defmodule BDS.UI.ShellTest do
  use ExUnit.Case, async: true

  alias BDS.UI.Commands
  alias BDS.UI.Registry
  alias BDS.UI.Session
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

    state = Commands.handle_shortcut(state, %{meta: true, key: ","})
    assert state.editor_route == :settings
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

  test "desktop shell keeps the compact frame metrics and live bootstrap assets" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    live_js = File.read!("/Users/gb/Projects/bDS2/priv/ui/live.js")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/app.css")
    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/live.js")
    assert css =~ ".window-titlebar"
    assert css =~ "height: 34px"
    assert css =~ "width: 48px"
    assert css =~ "height: 35px"
    assert css =~ "height: 22px"
    assert live_js =~ "LiveView.LiveSocket"
    assert live_js =~ "Phoenix.Socket"
    assert template =~ "data-project-id={@projects.active_project_id || \"\"}"
    assert template =~ "data-workbench-session={encoded_workbench_session(@workbench)}"
  end

  test "desktop shell assets persist workbench layout per project" do
    live_js = File.read!("/Users/gb/Projects/bDS2/priv/ui/live.js")
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")

    assert live_js =~ "bds-workbench-"
    assert live_js =~ "restore_workbench_session"
    assert live_js =~ "dataset.workbenchSession"
    assert live_ex =~ ~s(def handle_event("restore_workbench_session")
    assert live_ex =~ "Session.restore"
    assert live_ex =~ "encoded_workbench_session"
  end

  test "desktop shell css keeps the status bar and hidden menu alignment rules" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

    assert css =~ ".window-titlebar-menu-bar.is-hidden"
    assert css =~ "--vscode-statusBar-background: #007acc"
    assert css =~ ".status-bar-left,"
    assert css =~ ".status-shell-controls"
    assert css =~ ".status-shell-toggle-button"
    assert css =~ "gap: 4px"
    assert css =~ "padding: 0 8px"
    assert css =~ "height: 100%"
    refute css =~ "background: var(--status)"
    assert css =~ ".status-bar-language-select"
    assert css =~ ".status-bar-item.language-badge"
    assert css =~ ".status-bar-item.offline-badge"
  end

  test "desktop shell assets keep old activity, tab, focus, and titlebar overlay parity rules" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    live_js = File.read!("/Users/gb/Projects/bDS2/priv/ui/live.js")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert css =~ "color: var(--vscode-activityBar-foreground)"
    assert css =~ ".activity-bar-badge"
    assert css =~ ".tab-actions"
    assert css =~ ".tab-dirty-indicator"
    assert css =~ ".tab.dirty .tab-close"
    assert css =~ ".tab:focus-visible"
    assert css =~ ".window-titlebar-action-button:focus"
    assert css =~ ".panel-tab.active"
    assert css =~ "border-bottom-color: var(--vscode-focusBorder);"
    assert css =~ ".sidebar-section-header"
    assert css =~ "justify-content: space-between"
    assert css =~ "align-items: center"
    assert css =~ "padding-right: calc(10px + var(--bds-titlebar-overlay-right, 0px));"
    assert live_js =~ "windowControlsOverlay"
    assert live_js =~ "geometrychange"
    assert live_js =~ "--bds-titlebar-overlay-left"
    assert live_js =~ "dataset.shortcuts"
    assert live_js =~ "addEventListener(\"keydown\", this.handleShortcutKeyDown, true)"
    assert live_js =~ "event.preventDefault()"
    assert live_js =~ "this.pushEvent(\"shortcut\""
    assert template =~ "data-shortcuts={encoded_shortcuts(@client_shortcuts)}"
    assert template =~ "data-testid=\"status-shell-controls\""
    assert template =~ "activity-bar-badge"
    assert template =~ "tab-actions"
    assert template =~ "tab-dirty-indicator"
  end

  test "desktop shell css keeps the old activity bar active marker contrast" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

    assert css =~ "--vscode-activityBar-foreground: #ffffff"
    assert css =~ ".activity-bar-item:hover {"
    assert css =~ ".activity-bar-item.active::before {"
    assert css =~ "width: 2px;"
    assert css =~ "background-color: var(--vscode-activityBar-foreground);"
  end

  test "desktop shell assets keep legacy titlebar menu keyboard and anchoring behavior" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    live_js = File.read!("/Users/gb/Projects/bDS2/priv/ui/live.js")
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert css =~ ".window-titlebar-menu-group {"
    assert css =~ "left: 0;"
    refute live_js =~ "--bds-titlebar-menu-left"
    refute live_js =~ "syncTitlebarMenuAnchor"
    refute live_js =~ "handleTitlebarMenuKeyDown"
    refute live_js =~ "keyboardMenuIndex"
    assert template =~ "phx-window-keydown={if(@titlebar_menu_group, do: \"titlebar_menu_keydown\")}"
    assert template =~ "window-titlebar-menu-group"
    assert live_ex =~ ~s(def handle_event("titlebar_menu_keydown")
    assert live_ex =~ "titlebar_menu_item_index"
  end

  test "desktop shell status task area keeps the compact running-task markup" do
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert template =~ "task-message-text"
    assert template =~ "task-spinner"
    assert template =~ "status-bar-count"
  end

  test "desktop shell css keeps old panel and output density" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

    assert css =~ ".panel-content {"
    assert css =~ "padding: 8px;"
    assert css =~ ".task-spinner {"
    assert css =~ ".task-message-text"
    assert css =~ ".output-entry {"
    assert css =~ "background-color: var(--vscode-sideBar-background);"
    assert css =~ "border-radius: 4px;"
    assert css =~ ".task-entry {"
    assert css =~ "background-color: var(--vscode-sideBar-background);"
  end

  test "desktop shell css keeps legacy sidebar header and post list layout" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

    assert css =~ ".sidebar-section {"
    assert css =~ "margin-bottom: 4px;"
    assert css =~ "border-left: 2px solid transparent;"
    assert css =~ "border-left-color: var(--vscode-focusBorder);"
    assert css =~ ".sidebar-section-header {"
    assert css =~ "justify-content: space-between;"
    assert css =~ "font-weight: 600;"
    assert css =~ ".sidebar-item {"
    assert css =~ "align-items: flex-start;"
    assert css =~ "gap: 8px;"
  end

  test "desktop shell assets keep the assistant sidebar chat surface contract" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert css =~ ".assistant-sidebar-context"
    assert css =~ ".assistant-sidebar-prompt"
    assert css =~ ".assistant-sidebar-start-button"
    assert css =~ ".assistant-sidebar-message"
    assert template =~ "data-testid=\"assistant-context\""
    assert template =~ "data-testid=\"assistant-prompt-form\""
    assert template =~ "data-testid=\"assistant-prompt-input\""
    assert template =~ "data-testid=\"assistant-start-button\""
    assert template =~ "assistant-sidebar-transcript"
  end

  test "desktop shell css keeps the old assistant sidebar panel styling" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

    assert css =~ ".assistant-content {"
    assert css =~ "padding: 12px;"
    assert css =~ ".assistant-sidebar-context {"
    assert css =~ "padding: 8px;"
    assert css =~ "border-radius: 6px;"
    assert css =~ "background: var(--vscode-editorWidget-background, rgba(0, 0, 0, 0.2));"
    assert css =~ ".assistant-sidebar-prompt {"
    assert css =~ "min-height: 120px;"
    assert css =~ "padding: 10px;"
  end
end
