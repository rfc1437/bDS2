defmodule BDS.UI.ShellTest do
  use ExUnit.Case, async: true

  alias BDS.UI.Commands
  alias BDS.UI.Registry
  alias BDS.UI.Session
  alias BDS.UI.Workbench

  @css_sources [
    "tokens.css",
    "shell.css",
    "sidebar.css",
    "tabs.css",
    "editor.css",
    "forms.css",
    "panel.css",
    "assistant.css",
    "overlays.css",
    "menu_editor.css",
    "media_editor.css",
    "import_editor.css",
    "utilities.css"
  ]

  defp css_source do
    @css_sources
    |> Enum.map(&File.read!("/Users/gb/Projects/bDS2/assets/css/#{&1}"))
    |> Enum.join("\n")
  end

  defp live_js_source do
    Path.wildcard("/Users/gb/Projects/bDS2/assets/js/**/*.js")
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
    |> Enum.join("\n")
  end

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
    css = css_source()
    live_js = live_js_source()
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert File.exists?("/Users/gb/Projects/bDS2/assets/css/shell.css")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/app.js")
    assert css =~ ".window-titlebar"
    assert css =~ "height: 34px"
    assert css =~ "width: 48px"
    assert css =~ "height: 35px"
    assert css =~ "height: 22px"
    assert live_js =~ "new LiveSocket"
    assert live_js =~ "Socket"
    assert template =~ "data-project-id={@projects.active_project_id || \"\"}"
    assert template =~ "data-workbench-session={encoded_workbench_session(@workbench)}"
  end

  test "phase 4 css defines normalized shared primitives" do
    css = css_source()

    assert css =~ ".ui-button {"
    assert css =~ ".ui-button-secondary {"
    assert css =~ ".ui-button-danger {"
    assert css =~ ".ui-input,"
    assert css =~ ".ui-textarea {"
    assert css =~ ".ui-tab {"
    assert css =~ ".ui-badge {"
    assert css =~ ".ui-panel-entry {"
    assert css =~ ".ui-empty-state {"
    assert css =~ ".ui-editor-shell {"
    assert css =~ ".ui-editor-header {"
    assert css =~ ".ui-editor-tab-current {"
    assert css =~ ".ui-editor-actions {"
    assert css =~ ".ui-toolbar {"
    assert css =~ ".ui-toolbar-group {"
    assert css =~ ".ui-field-stack {"
    assert css =~ ".ui-field-grid-2 {"
    assert css =~ ".ui-field-grid-3 {"
    assert css =~ ".ui-dropdown-menu {"
    assert css =~ ".ui-dropdown-item {"
    assert css =~ ".ui-section-card {"
  end

  test "phase 3 templates use shared shell and form primitives for common layout" do
    post_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/post_editor_html/post_editor.html.heex"
      )

    media_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/media_editor_html/media_editor.html.heex"
      )

    script_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/script_editor_html/script_editor.html.heex"
      )

    template_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/template_editor_html/template_editor.html.heex"
      )

    chat_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/chat_editor_html/chat_editor.html.heex"
      )

    menu_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/menu_editor_html/menu_editor.html.heex"
      )

    settings_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/settings_editor_html/settings_editor.html.heex"
      )

    assert post_template =~ "ui-editor-shell"
    assert post_template =~ "ui-editor-header"
    assert post_template =~ "ui-editor-tab-current"
    assert post_template =~ "ui-editor-actions"
    assert post_template =~ "ui-field-stack"
    assert post_template =~ "ui-field-grid-2"
    assert post_template =~ "ui-toolbar"
    assert post_template =~ "ui-toolbar-group"
    assert post_template =~ "ui-dropdown-menu"
    assert post_template =~ "ui-dropdown-item"

    assert media_template =~ "ui-editor-shell"
    assert media_template =~ "ui-editor-header"
    assert media_template =~ "ui-editor-tab-current"
    assert media_template =~ "ui-editor-actions"
    assert media_template =~ "ui-field-stack"
    assert media_template =~ "ui-field-grid-2"
    assert media_template =~ "ui-dropdown-menu"
    assert media_template =~ "ui-dropdown-item"

    assert script_template =~ "ui-editor-shell"
    assert script_template =~ "ui-editor-header"
    assert script_template =~ "ui-editor-tab-current"
    assert script_template =~ "ui-editor-actions"
    assert script_template =~ "ui-field-stack"

    assert template_template =~ "ui-editor-shell"
    assert template_template =~ "ui-editor-header"
    assert template_template =~ "ui-editor-tab-current"
    assert template_template =~ "ui-editor-actions"
    assert template_template =~ "ui-field-stack"

    assert chat_template =~ "ui-editor-shell"
    assert chat_template =~ "ui-section-card"
    assert chat_template =~ "ui-dropdown-menu"
    assert chat_template =~ "ui-dropdown-item"
    assert chat_template =~ "ui-field-stack"

    assert menu_template =~ "ui-editor-shell"
    assert menu_template =~ "ui-section-card"
    assert menu_template =~ "ui-toolbar"

    assert settings_template =~ "ui-editor-shell"
    assert settings_template =~ "ui-field-stack"
    assert settings_template =~ "ui-section-card"
  end

  test "phase 3 trims redundant common-case layout rules from authored css slices" do
    editor_css = File.read!("/Users/gb/Projects/bDS2/assets/css/editor.css")
    media_css = File.read!("/Users/gb/Projects/bDS2/assets/css/media_editor.css")
    assistant_css = File.read!("/Users/gb/Projects/bDS2/assets/css/assistant.css")
    menu_css = File.read!("/Users/gb/Projects/bDS2/assets/css/menu_editor.css")

    refute editor_css =~
             ".post-editor .editor-header,\n.scripts-view-shell.editor .editor-header,\n.templates-view-shell.editor .editor-header {\n  display: flex;"

    refute editor_css =~
             ".post-editor .editor-actions,\n.scripts-view-shell.editor .editor-actions,\n.templates-view-shell.editor .editor-actions {\n  display: flex;"

    refute editor_css =~ ".post-editor .quick-actions-menu {"
    refute media_css =~ "[data-testid=\"media-editor\"] .editor-header {"
    refute media_css =~ "[data-testid=\"media-editor\"] .editor-actions {"
    refute media_css =~ "[data-testid=\"media-editor\"] .quick-actions-menu {"
    refute assistant_css =~ ".chat-panel-header {\n  display: flex;"
    refute assistant_css =~ ".chat-panel .chat-input-wrapper {\n  display: flex;"
    refute menu_css =~ ".menu-editor-view {\n  padding: 1rem;"
    refute menu_css =~ ".menu-editor-toolbar {\n  display: flex;"
  end

  test "phase 5 desktop-specific surfaces stay in source modules with responsive behavior" do
    css = css_source()
    app_js = live_js_source()

    assert css =~ ".ai-suggestions-modal-backdrop"
    assert css =~ ".gallery-overlay"
    assert css =~ ".lightbox-overlay"

    assert css =~ ".menu-editor-row.is-dragging"
    assert css =~ ".menu-editor-row.is-drop-before::before"
    assert css =~ ".menu-editor-row.is-drop-after::after"
    assert css =~ ".menu-editor-row.is-drop-inside"
    assert app_js =~ "MenuEditorTree"
    assert app_js =~ "classList.add(\"is-dragging\")"
    assert app_js =~ "pushEvent(\"menu_editor_drop_item\""

    assert css =~ ".media-preview {"
    assert css =~ ".media-preview-image img {"
    assert css =~ "object-fit: contain;"
    assert css =~ ".media-details {"
    assert css =~ "width: 320px;"

    assert css =~ ".assistant-sidebar-context {"
    assert css =~ ".assistant-sidebar-message {"
    assert css =~ ".chat-panel .chat-input-container"
    assert css =~ ".chat-model-selector-menu"

    assert css =~
             "@media (max-width: 720px) {\n  .chat-panel-header {\n    align-items: stretch;\n    flex-direction: column;"

    assert css =~ ".chat-model-selector-wrap {\n    width: 100%;"

    assert css =~
             ".chat-panel .chat-model-selector-button.chat-model-selector-inline {\n    justify-content: space-between;\n    width: 100%;"

    assert css =~ ".chat-panel .chat-input-container {\n    padding: 8px 12px;"
  end

  test "tailwind source keeps theme tokens and shared component primitives" do
    css = css_source()
    app_css = File.read!("/Users/gb/Projects/bDS2/assets/css/app.css")

    assert app_css =~ ~s|@import "tailwindcss" source(none);|
    assert css =~ "@theme"
    assert css =~ "--color-shell-bg:"
    assert css =~ "--font-sans:"
    assert css =~ "@layer components"
    assert css =~ ".btn-base"
    assert css =~ ".btn-theme-primary"
    assert css =~ ".btn-theme-danger"
    assert css =~ ".panel-entry"
    assert css =~ ".monaco-host"
  end

  test "live javascript is split into focused Phoenix asset modules" do
    app_js = File.read!("/Users/gb/Projects/bDS2/assets/js/app.js")
    hooks_index = File.read!("/Users/gb/Projects/bDS2/assets/js/hooks/index.js")

    assert app_js =~ ~s(import { Hooks } from "./hooks/index.js";)
    assert hooks_index =~ ~s(import { AppShell } from "./app_shell.js";)
    assert hooks_index =~ ~s(import { ChatSurface } from "./chat_surface.js";)
    assert hooks_index =~ ~s(import { MenuEditorTree } from "./menu_editor_tree.js";)
    assert hooks_index =~ ~s(import { MonacoEditor } from "./monaco_editor.js";)
    assert hooks_index =~ ~s(import { MonacoDiffEditor } from "./monaco_diff_editor.js";)
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/index.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/app_shell.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/chat_surface.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/menu_editor_tree.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/monaco_editor.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/monaco_diff_editor.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/sidebar_interactions.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/hooks/section_scroll.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/bridges/titlebar_overlay.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/bridges/menu_runtime.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/bridges/document_commands.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/monaco/services.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/monaco/theme.js")
    assert File.exists?("/Users/gb/Projects/bDS2/assets/js/monaco/languages.js")
  end

  test "top level shell render uses utility classes for common layout" do
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert template =~ ~s(class="app flex h-full w-full flex-col")
    assert template =~ ~s(class="app-main flex min-h-0 flex-1 overflow-hidden")
    assert template =~ ~s(class="app-content flex min-w-0 flex-1 flex-col overflow-hidden")
    assert template =~ ~s(class="tab-bar flex h-[35px] shrink-0 items-center overflow-hidden")
  end

  test "desktop shell css keeps editor and help docs on the VS Code dark surface" do
    css = css_source()

    assert css =~ ".post-editor .post-editor-markdown-surface"
    assert css =~ ".scripts-monaco.monaco-editor-shell"
    assert css =~ ".templates-monaco.monaco-editor-shell"
    assert css =~ ".help-doc-markdown"
    assert css =~ "background: var(--vscode-editor-background);"
    assert css =~ "color: var(--vscode-editor-foreground);"
    refute Regex.match?(~r/\.sidebar-item\s*\{[^}]*background:\s*var\(--panel-2\)/s, css)
    refute Regex.match?(~r/\.sidebar-item\s*\{[^}]*color:\s*var\(--ink\)/s, css)
  end

  test "desktop help documentation keeps the old markdown viewer styling contract" do
    css = css_source()

    assert css =~ ".help-doc-view"
    assert css =~ ".help-doc-view .misc-editor-content"
    assert css =~ ".documentation-article"
    assert css =~ ".documentation-content.markdown-body h1"
    assert css =~ ".documentation-content.markdown-body table"
    assert css =~ ".documentation-content.markdown-body ul"
    assert css =~ "background: var(--doc-surface);"
    assert css =~ "box-shadow: 0 10px 24px rgba(0, 0, 0, 0.18);"
  end

  test "desktop settings editor keeps the old preferences styling contract" do
    css = css_source()

    assert css =~ ".settings-view"
    assert css =~ ".settings-header"
    assert css =~ ".settings-content"
    assert css =~ ".setting-section"
    assert css =~ ".setting-section-header"
    assert css =~ ".setting-section-content"
    assert css =~ ".setting-row"
    assert css =~ ".setting-control"
    assert css =~ "grid-template-columns: minmax(180px, 240px) minmax(0, 1fr);"
    assert css =~ "background: var(--panel-2, #252526);"
    assert css =~ "border: 1px solid var(--line, #3c3c3c);"
  end

  test "monaco editor styling forces the internal editor surface to the dark theme" do
    css = css_source()
    live_js = live_js_source()

    assert css =~ ".monaco-editor .margin"
    assert css =~ ".monaco-editor-background"
    assert css =~ "background-color: var(--vscode-editor-background) !important;"
    assert css =~ ".monaco-editor .view-line"
    assert live_js =~ "base: \"vs-dark\""
    assert live_js =~ "monaco.editor.setTheme(\"bds-theme\");"
  end

  test "monaco editor hook forces first visible layout and textarea content sync" do
    live_js = live_js_source()

    assert live_js =~ "this.syncEditorFromTextarea"
    assert live_js =~ "this.layoutEditorSoon"
    assert live_js =~ "this.waitForMonacoVisibleSize"
    assert live_js =~ "ResizeObserver"
    assert live_js =~ "requestAnimationFrame"
    assert live_js =~ "this.editor.layout()"
    assert live_js =~ "this.syncEditorFromTextarea()"
  end

  test "monaco theme uses normalized app colors before defining the dark theme" do
    live_js = live_js_source()

    assert live_js =~ "normalizeMonacoColor"
    assert live_js =~ "base: \"vs-dark\""
    assert live_js =~ "\"editor.background\": background"
    assert live_js =~ "monaco.editor.defineTheme(\"bds-theme\""
  end

  test "desktop shell assets persist workbench layout per project" do
    live_js = live_js_source()
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")

    session_util_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/session_util.ex")

    assert live_js =~ "bds-workbench-"
    assert live_js =~ "restore_workbench_session"
    assert live_js =~ "dataset.workbenchSession"
    assert live_ex =~ ~s(def handle_event("restore_workbench_session")
    assert session_util_ex =~ "Session.restore"
    assert live_ex =~ "encoded_workbench_session"
  end

  test "desktop shell assets reveal loaded media sidebar thumbnails" do
    css = css_source()
    live_js = live_js_source()

    assert css =~ ".media-thumbnail.is-loaded .media-thumbnail-image"
    assert css =~ ".media-thumbnail.is-loaded .media-thumbnail-fallback"
    assert live_js =~ "media-thumbnail-image"
    assert live_js =~ "classList.add(\"is-loaded\")"
    assert live_js =~ "classList.remove(\"is-loaded\")"
  end

  test "desktop shell css keeps the status bar and hidden menu alignment rules" do
    css = css_source()

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
    css = css_source()
    live_js = live_js_source()
    titlebar_js = File.read!("/Users/gb/Projects/bDS2/assets/js/bridges/titlebar_overlay.js")
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
    assert titlebar_js =~ "windowControlsOverlay"
    assert titlebar_js =~ "geometrychange"
    assert titlebar_js =~ "--bds-titlebar-overlay-left"
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

  test "desktop shell keeps sidebar delete buttons visible in the default state" do
    css = css_source()

    assert Regex.match?(~r/\.sidebar-delete-button\s*\{[^}]*opacity:\s*1;/s, css)
    refute Regex.match?(~r/\.sidebar-delete-button\s*\{[^}]*opacity:\s*0;/s, css)
  end

  test "desktop shell css keeps the old activity bar active marker contrast" do
    css = css_source()

    assert css =~ "--vscode-activityBar-foreground: #ffffff"
    assert css =~ ".activity-bar-item:hover {"
    assert css =~ ".activity-bar-item.active::before {"
    assert css =~ "width: 2px;"
    assert css =~ "background-color: var(--vscode-activityBar-foreground);"
  end

  test "desktop shell assets keep legacy titlebar menu keyboard and anchoring behavior" do
    css = css_source()
    live_js = live_js_source()
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert css =~ ".window-titlebar-menu-group {"
    assert css =~ "left: 0;"
    refute live_js =~ "--bds-titlebar-menu-left"
    refute live_js =~ "syncTitlebarMenuAnchor"
    refute live_js =~ "handleTitlebarMenuKeyDown"
    refute live_js =~ "keyboardMenuIndex"

    assert template =~
             "phx-window-keydown={if(@titlebar_menu_group, do: \"titlebar_menu_keydown\")}"

    assert template =~ "window-titlebar-menu-group"
    assert live_ex =~ ~s(def handle_event("titlebar_menu_keydown")
    assert live_ex =~ "titlebar_menu_item_index"
  end

  test "desktop shell css keeps the old media editor layout contract" do
    css = css_source()

    template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/media_editor_html/media_editor.html.heex"
      )

    assert css =~ ".media-preview {"
    assert css =~ "min-height: 300px;"
    assert css =~ ".media-preview-image {"
    assert css =~ "width: 100%;"
    assert css =~ "height: 100%;"
    assert css =~ "box-sizing: border-box;"
    assert css =~ ".media-preview-image img {"
    assert css =~ "object-fit: contain;"
    assert css =~ ".media-details {"
    assert css =~ "width: 320px;"
    assert css =~ ".media-details textarea {"
    assert css =~ "resize: vertical;"
    assert css =~ ".linked-posts-section label {"
    assert css =~ "justify-content: space-between;"
    assert css =~ ".add-link-btn {"
    assert css =~ "font-size: 11px;"
    assert css =~ ".post-picker {"
    assert css =~ "max-height: 250px;"
    assert css =~ ".post-picker-search input {"
    assert css =~ "padding: 6px 10px;"
    assert css =~ ".linked-post-item:hover .unlink-btn {"
    assert css =~ "opacity: 1;"

    assert Regex.match?(
             ~r/class="secondary quick-actions-btn ui-button ui-button-secondary inline-flex items-center gap-2".*?<span class="quick-actions-btn-icon">⚡<\/span>\s*<span class="quick-actions-btn-label"><%= dgettext\("ui", "Quick Actions"\) %><\/span>/s,
             template
           )

    assert template =~ ~s(class="quick-action-text flex min-w-0 flex-1 flex-col")
    assert template =~ ~s(class="quick-action-icon">🤖</span>)

    assert Regex.match?(
             ~r/class="quick-action-text[^"]*">\s*<strong><%= dgettext\("ui", "AI Suggestions"\) %><\/strong>.*?<\/span>\s*<span class="quick-action-icon">🤖<\/span>/s,
             template
           )

    refute template =~ ~s|<span class="quick-action-icon">🤖</span>
          <span class="quick-action-text">|
  end

  test "desktop shell status task area keeps the compact running-task markup" do
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    assert template =~ "task-message-text"
    assert template =~ "task-spinner"
    assert template =~ "status-bar-count"
  end

  test "desktop shell css keeps old panel and output density" do
    css = css_source()

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
    css = css_source()

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
    css = css_source()
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

  test "desktop shell assets expose the shared overlay render contract" do
    css = css_source()
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    overlay_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/overlay_components.ex")

    overlay_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/overlay_html/shell_overlay.html.heex"
      )

    assert template =~ "render_editor_toolbar(assigns)"
    assert template =~ "<ShellOverlayComponents.shell_overlay"

    assert live_ex =~ ~s(def handle_event("open_overlay")
    assert live_ex =~ ~s(def handle_event("close_overlay")
    assert live_ex =~ ~s(def handle_event("overlay_keydown")
    assert overlay_ex =~ "def context(assigns, tab_title, tab_subtitle)"
    assert overlay_template =~ "ai-suggestions-modal"
    assert overlay_template =~ "confirm-delete-modal"
    assert overlay_template =~ "insert-modal"
    assert overlay_template =~ "language-picker-modal"
    assert overlay_template =~ "gallery-overlay"
    assert overlay_template =~ "lightbox-overlay"

    assert css =~ ".shell-overlay-backdrop"
    assert css =~ ".ai-suggestions-modal-backdrop"
    assert css =~ ".confirm-delete-modal-backdrop"
    assert css =~ ".insert-modal-backdrop"
    assert css =~ ".language-picker-modal-backdrop"
    assert css =~ ".gallery-overlay"
    assert css =~ ".lightbox-overlay"
  end

  test "desktop shell keeps post editor logic in the feature slice" do
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    post_editor_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/post_editor.ex")

    post_template =
      File.read!(
        "/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/post_editor_html/post_editor.html.heex"
      )

    assert template =~ "<.live_component module={PostEditor}"
    assert post_editor_ex =~ "defp build_data(socket)"

    assert Regex.match?(
             ~r/class="secondary quick-actions-btn ui-button ui-button-secondary inline-flex items-center gap-2".*?<span class="quick-actions-btn-icon">⚡<\/span>\s*<span class="quick-actions-btn-label"><%= dgettext\("ui", "Quick Actions"\) %><\/span>/s,
             post_template
           )

    refute live_ex =~ "defp update_post_editor("
    refute live_ex =~ "defp persist_post_editor("
    refute live_ex =~ "defp discard_post_editor("
    refute live_ex =~ "defp delete_post_editor("
    refute live_ex =~ "defp update_post_editor_expanded("
  end

  test "desktop shell keeps media editor logic in the feature slice" do
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    media_editor_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/media_editor.ex")

    assert template =~ "<.live_component module={MediaEditor}"
    assert media_editor_ex =~ "defp build_data(socket)"

    refute live_ex =~ "defp update_media_editor("
    refute live_ex =~ "defp persist_media_editor("
    refute live_ex =~ "defp delete_media_editor("
  end

  test "desktop shell keeps sidebar logic in its own slice" do
    live_ex = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex")
    template = File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/index.html.heex")

    sidebar_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/sidebar_components.ex")

    sidebar_state_ex =
      File.read!("/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live/sidebar_state.ex")

    assert template =~ "<ShellSidebarComponents.sidebar_content"
    assert sidebar_ex =~ "def sidebar_content(assigns)"
    assert sidebar_state_ex =~ "def current_filters(socket, view_id)"

    refute live_ex =~ "defp render_sidebar_filters("
    refute live_ex =~ "defp render_sidebar_load_more("
    refute live_ex =~ "defp render_sidebar_body("
    refute live_ex =~ "defp render_post_sidebar("
    refute live_ex =~ "defp render_media_sidebar("
    refute live_ex =~ "defp render_entity_sidebar("
    refute live_ex =~ "defp render_nav_sidebar("
    refute live_ex =~ "defp render_default_sidebar("
    refute live_ex =~ "defp merge_sidebar_ui_state("
    refute live_ex =~ "defp sidebar_filter_panel_state("
    refute live_ex =~ "defp put_sidebar_filter_panel_state("
    refute live_ex =~ "defp current_sidebar_filters("
    refute live_ex =~ "defp put_sidebar_filters("
  end

  test "desktop shell css keeps the old assistant sidebar panel styling" do
    css = css_source()

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
