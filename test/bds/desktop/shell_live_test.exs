defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  test "shell live owns pane visibility and activity selection on the server" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-shell")
    assert html =~ ~s(data-testid="status-bar")
    assert html =~ ~s(data-testid="status-task-button")
    assert html =~ ~s(class="panel-shell is-hidden")
    assert html =~ ~s(data-testid="activity-button")
    assert html =~ ~s(data-view="posts")
    assert html =~ ~s(data-view="media")
    assert html =~ ~s(aria-label="Posts")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    assert html =~ ~s(class="sidebar-shell is-hidden")

    html =
      view
      |> element("[data-testid='toggle-panel']")
      |> render_click()

    assert html =~ ~s(data-region="panel")
    refute html =~ ~s(class="panel-shell is-hidden")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='media']")
      |> render_click()

    assert html =~ ~s(aria-label="Media")
    assert html =~ ~s(data-view="media")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='settings']")
      |> render_click()

    assert html =~ ~s(data-testid="sidebar-open-item")

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='settings-project']")
      |> render_click()

    assert html =~ ~s(data-tab-type="settings")
    assert html =~ ">Settings<"

    html =
      view
      |> element("[data-testid='tab-close'][data-tab-type='settings'][data-tab-id='settings']")
      |> render_click()

    refute html =~ ~s(data-tab-type="settings")
    assert html =~ ~s(class="tab-bar-empty")
  end

  test "sidebar open supports preview and pin intents for entity tabs" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "open_sidebar_item", %{
        "route" => "post",
        "id" => "post-1",
        "title" => "First Post",
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="post-1")
    assert html =~ ~s(class="tab active transient")

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => "post-1",
        "title" => "First Post",
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-tab-id="post-1")
    refute html =~ ~s(class="tab active transient")

    html =
      render_click(view, "open_sidebar_item", %{
        "route" => "post",
        "id" => "page-1",
        "title" => "About Page",
        "subtitle" => "page"
      })

    assert html =~ ~s(data-tab-id="post-1")
    assert html =~ ~s(data-tab-id="page-1")
    assert String.contains?(html, ">First Post<")
    assert String.contains?(html, ">About Page<")

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => "media-1",
        "title" => "hero.png",
        "subtitle" => "12 KB"
      })

    html =
      render_click(view, "open_sidebar_item", %{
        "route" => "media",
        "id" => "media-2",
        "title" => "cover.png",
        "subtitle" => "8 KB"
      })

    assert html =~ ~s(data-tab-id="media-1")
    assert html =~ ~s(data-tab-id="media-2")
    assert String.contains?(html, ">hero.png<")
    assert String.contains?(html, ">cover.png<")
  end

  test "global shortcuts route through the shared command model" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-shell")
    assert html =~ ~s(class="panel-shell is-hidden")

    html = render_keydown(view, "shortcut", %{key: "b", meta: true})
    assert html =~ ~s(class="sidebar-shell is-hidden")

    html = render_keydown(view, "shortcut", %{key: "j", meta: true})
    refute html =~ ~s(class="panel-shell is-hidden")

    html = render_keydown(view, "shortcut", %{key: "2", meta: true})
    assert html =~ ~s(data-view="media")

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => "media-1",
        "title" => "hero.png",
        "subtitle" => "12 KB"
      })

    assert html =~ ~s(data-tab-id="media-1")

    html = render_keydown(view, "shortcut", %{key: "w", meta: true})
    refute html =~ ~s(data-tab-id="media-1")
  end
end
