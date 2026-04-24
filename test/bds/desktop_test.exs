defmodule BDS.DesktopTest do
  use ExUnit.Case, async: false

  import Plug.Test

  test "desktop configuration no longer uses a pending adapter" do
    assert Application.get_env(:bds, BDS.Application)[:desktop_adapter] == :desktop
  end

  test "desktop child specs include the local shell server and desktop window in non-test environments" do
    children = BDS.Application.desktop_children(:dev)

    assert Enum.any?(children, fn child ->
             match?({BDS.Desktop.Server, _opts}, child)
           end)

    assert Enum.any?(children, fn child ->
             match?({Desktop.Window, opts} when is_list(opts), child) and
               Keyword.fetch!(elem(child, 1), :id) == BDS.Desktop.MainWindow
           end)
  end

  test "desktop children stay disabled in test so command-line tests do not spawn wx windows" do
    assert BDS.Application.desktop_children(:test) == []
  end

  test "desktop shell url points at the embedded shell route" do
    url = BDS.Desktop.url(4011)

    assert url == "http://127.0.0.1:4011/"
  end

  test "desktop menu bar exposes the native menu groups for the shell window" do
    groups = BDS.Desktop.MenuBar.groups(dev_mode?: false)

    assert Enum.map(groups, & &1.id) == [:app, :file, :edit, :view, :window, :help]

    view_group = Enum.find(groups, &(&1.id == :view))
    assert :toggle_sidebar in Enum.map(view_group.items, & &1.id)
    assert :toggle_panel in Enum.map(view_group.items, & &1.id)
    assert :toggle_assistant_sidebar in Enum.map(view_group.items, & &1.id)
  end

  test "desktop shell html follows the old app frame regions and references bundled assets" do
    html = BDS.Desktop.ShellController.index_html()

    assert html =~ ~s(class="app")
    assert html =~ ~s(class="window-titlebar")
    assert html =~ ~s(class="activity-bar")
    assert html =~ ~s(class="sidebar")
    assert html =~ ~s(class="tab-bar")
    assert html =~ ~s(class="status-bar")
    assert html =~ ~s(src="/assets/app.js")
    assert html =~ ~s(href="/assets/app.css")
  end

  test "desktop router serves the shell without requiring Phoenix endpoint secrets" do
    conn = conn(:get, "/?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ ~s(class="app")
  end
end