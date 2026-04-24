defmodule BDS.DesktopTest do
  use ExUnit.Case, async: false

  import Plug.Test

  test "desktop configuration no longer uses a pending adapter" do
    assert Application.get_env(:bds, BDS.Application)[:desktop_adapter] == :desktop
  end

  test "desktop child specs include the local shell server and desktop window in non-test environments" do
    children = BDS.Application.desktop_children(:dev)
    child_ids = Enum.map(children, &Supervisor.child_spec(&1, []).id)

    assert Enum.any?(children, fn child ->
             match?({BDS.Desktop.Server, _opts}, child)
           end)

    assert Enum.any?(children, fn child ->
             match?({Desktop.Window, opts} when is_list(opts), child) and
               Keyword.fetch!(elem(child, 1), :id) == BDS.Desktop.MainWindow
           end)

    assert Enum.uniq(child_ids) == child_ids
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
    item_ids = fn items ->
      items
      |> Enum.reject(&Map.get(&1, :separator, false))
      |> Enum.map(& &1.id)
    end

    assert Enum.map(groups, & &1.id) == [:file, :edit, :view, :blog, :help]

    view_group = Enum.find(groups, &(&1.id == :view))
    assert :toggle_sidebar in item_ids.(view_group.items)
    assert :toggle_panel in item_ids.(view_group.items)
    assert :toggle_assistant_sidebar in item_ids.(view_group.items)

    blog_group = Enum.find(groups, &(&1.id == :blog))
    blog_actions = item_ids.(blog_group.items)

    assert :metadata_diff in blog_actions
    assert :edit_menu in blog_actions
    assert :rebuild_database in blog_actions
    assert :find_duplicates in blog_actions
    assert :validate_site in blog_actions

    help_group = Enum.find(groups, &(&1.id == :help))
    help_actions = item_ids.(help_group.items)

    assert :documentation in help_actions
    assert :api_documentation in help_actions
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

  test "desktop router exposes live task status for shell polling" do
    assert {:ok, task} =
             BDS.Tasks.register_external_task("preview build", %{
               group_id: "generation",
               group_name: "Generation"
             })

    on_exit(fn ->
      _ = BDS.Tasks.complete_task(task.id)
    end)

    assert :ok = BDS.Tasks.report_progress(task.id, 0.5, "halfway")

    conn = conn(:get, "/api/tasks?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    payload = Jason.decode!(conn.resp_body)

    assert payload["active_count"] >= 1
    assert payload["running_task_message"] == "preview build: halfway"

    assert Enum.any?(payload["tasks"], fn item ->
             item["id"] == task.id and item["group_name"] == "Generation" and item["progress"] == 0.5
           end)
  end

    test "desktop router executes shell commands through the JSON api" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Preview))

      temp_dir = Path.join(System.tmp_dir!(), "bds-desktop-router-#{System.unique_integer([:positive])}")
      File.mkdir_p!(temp_dir)

      on_exit(fn ->
        File.rm_rf(temp_dir)
        _ = BDS.Preview.stop_preview("default")
      end)

      {:ok, project} = BDS.Projects.create_project(%{name: "Desktop Router", data_path: temp_dir})
      {:ok, _project} = BDS.Projects.set_active_project(project.id)

      conn =
        conn(:post, "/api/commands?k=#{Desktop.Auth.login_key()}", Jason.encode!(%{"action" => "open_in_browser"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      payload = Jason.decode!(conn.resp_body)

      assert payload["result"]["kind"] == "open_url"
      assert payload["result"]["project_id"] == project.id
      assert payload["result"]["url"] == "http://127.0.0.1:4123/"
    end
end
