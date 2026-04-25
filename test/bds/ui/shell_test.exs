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

    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/app.css")
    assert File.exists?("/Users/gb/Projects/bDS2/priv/ui/live.js")
    assert css =~ ".window-titlebar"
    assert css =~ "height: 34px"
    assert css =~ "width: 48px"
    assert css =~ "height: 35px"
    assert css =~ "height: 22px"
    assert live_js =~ "LiveView.LiveSocket"
    assert live_js =~ "Phoenix.Socket"
  end

  test "desktop shell css keeps the status bar and hidden menu alignment rules" do
    css = File.read!("/Users/gb/Projects/bDS2/priv/ui/app.css")

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
  end
end
