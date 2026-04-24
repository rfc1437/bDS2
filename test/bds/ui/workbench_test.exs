defmodule BDS.UI.WorkbenchTest do
  use ExUnit.Case, async: true

  alias BDS.UI.MenuBar
  alias BDS.UI.Workbench

  test "preview tabs reuse the transient slot per type and route editors through the active tab" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:post, "post-1", :preview)

    assert state.active_tab == {:post, "post-1"}
    assert state.editor_route == :post
    assert [%{type: :post, id: "post-1", is_transient: true}] = state.tabs

    state = Workbench.open_tab(state, :post, "post-2", :preview)

    assert state.active_tab == {:post, "post-2"}
    assert state.editor_route == :post
    assert [%{type: :post, id: "post-2", is_transient: true}] = state.tabs
  end

  test "opening an existing preview tab as pinned upgrades it instead of duplicating it" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:post, "post-1", :preview)
      |> Workbench.open_tab(:post, "post-1", :pin)

    assert state.active_tab == {:post, "post-1"}
    assert [%{type: :post, id: "post-1", is_transient: false}] = state.tabs
  end

  test "singleton tabs deduplicate and are never transient" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:settings, "settings", :preview)
      |> Workbench.open_tab(:settings, "settings", :pin)

    assert state.active_tab == {:settings, "settings"}
    assert [%{type: :settings, id: "settings", is_transient: false}] = state.tabs
  end

  test "background opening keeps the active editor unchanged while still applying tab policy" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:post, "post-1", :pin)
      |> Workbench.open_tab_in_background(:media, "media-1", :preview)

    assert state.active_tab == {:post, "post-1"}
    assert state.editor_route == :post

    assert Enum.map(state.tabs, &{&1.type, &1.id, &1.is_transient}) == [
             {:post, "post-1", false},
             {:media, "media-1", true}
           ]
  end

  test "closing the active tab activates the next tab at the same index and falls back to dashboard" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:post, "post-1", :pin)
      |> Workbench.open_tab(:media, "media-1", :pin)
      |> Workbench.open_tab(:chat, "conversation-1", :pin)

    state = Workbench.close_tab(state, :media, "media-1")

    assert state.active_tab == {:chat, "conversation-1"}
    assert state.editor_route == :chat

    state =
      state
      |> Workbench.close_tab(:chat, "conversation-1")
      |> Workbench.close_tab(:post, "post-1")

    assert state.tabs == []
    assert state.active_tab == nil
    assert state.editor_route == :dashboard
  end

  test "activity clicks switch sidebar views and toggle visibility when re-clicking the active view" do
    state = Workbench.new()

    assert state.active_view == :posts
    assert state.sidebar_visible == true

    state = Workbench.click_activity(state, :posts)
    assert state.sidebar_visible == false
    assert state.active_view == :posts

    state = Workbench.click_activity(state, :media)
    assert state.sidebar_visible == true
    assert state.active_view == :media

    buttons = Workbench.activity_buttons(state, 108)
    media_button = Enum.find(buttons, &(&1.id == :media))
    git_button = Enum.find(buttons, &(&1.id == :git))

    assert media_button.active == true
    assert git_button.badge.display == "99+"
  end

  test "panel tab availability falls back to tasks when the active editor no longer supports the panel" do
    state =
      Workbench.new()
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(:post_links)
      |> Workbench.open_tab(:post, "post-1", :pin)

    assert state.panel.active_tab == :post_links

    state = Workbench.open_tab(state, :settings, "settings", :pin)

    assert state.editor_route == :settings
    assert state.panel.active_tab == :tasks

    state = Workbench.set_panel_tab(state, :git_log)
    state = Workbench.open_tab(state, :media, "media-1", :pin)
    assert state.panel.active_tab == :git_log
  end

  test "status bar data follows the active editor kind" do
    state =
      Workbench.new()
      |> Workbench.open_tab(:post, "post-1", :pin)

    status =
      Workbench.status_bar(state,
        post_count: 12,
        media_count: 7,
        theme_badge: "zinc",
        ui_language: "de",
        offline_mode: true,
        running_task_message: "Generating site",
        running_task_overflow: 2,
        active_post_status: :draft,
        token_usage: %{input_tokens: 10, output_tokens: 20, cache_read_tokens: 3}
      )

    assert status.left.running_task_message == "Generating site"
    assert status.right.post_status == "draft"
    assert status.right.post_count == "12 posts"
    assert status.right.media_count == "7 media"
    assert status.right.token_usage == nil

    state = Workbench.open_tab(state, :chat, "conversation-1", :pin)

    status =
      Workbench.status_bar(state,
        post_count: 12,
        media_count: 7,
        theme_badge: "zinc",
        ui_language: "de",
        offline_mode: true,
        token_usage: %{input_tokens: 10, output_tokens: 20, cache_read_tokens: 3}
      )

    assert status.right.post_status == nil
    assert status.right.token_usage == %{input_tokens: 10, output_tokens: 20, cache_read_tokens: 3}
  end

  test "menu commands expose generic shell controls through a shared command model" do
    state = Workbench.new(sidebar_visible: false, panel_visible: false)
    groups = MenuBar.default_groups(dev_mode?: false)
    item_ids = fn items ->
      items
      |> Enum.reject(&Map.get(&1, :separator, false))
      |> Enum.map(& &1.id)
    end

    assert Enum.map(groups, & &1.id) == [:file, :edit, :view, :blog, :help]

    view_group = Enum.find(groups, &(&1.id == :view))
    command_ids = item_ids.(view_group.items)

    assert :toggle_sidebar in command_ids
    assert :toggle_panel in command_ids
    refute :toggle_dev_tools in command_ids

    blog_group = Enum.find(groups, &(&1.id == :blog))
    assert :metadata_diff in item_ids.(blog_group.items)

    state = MenuBar.execute(state, :toggle_sidebar)
    state = MenuBar.execute(state, :toggle_panel)

    assert state.sidebar_visible == true
    assert state.panel.visible == true
  end
end
