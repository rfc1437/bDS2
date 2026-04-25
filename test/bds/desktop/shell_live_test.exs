defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  test "shell live owns pane visibility and activity selection on the server" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-shell")
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
  end
end
