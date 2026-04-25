defmodule BDS.DesktopTest do
  use ExUnit.Case, async: false

  import Plug.Test

  defmodule TestFolderPicker do
    def choose_directory(_prompt), do: Process.get(:test_folder_picker_response, :cancel)
  end

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

  test "desktop menu bar exposes native accelerator labels for system menu items" do
    groups = BDS.Desktop.MenuBar.groups(dev_mode?: false)

    assert menu_item(groups, :new_post).native_label == "New Post\tCTRL+N"
    assert menu_item(groups, :import_media).native_label == "Import Media\tCTRL+I"
    assert menu_item(groups, :save).native_label == "Save\tCTRL+S"
    assert menu_item(groups, :close_tab).shortcut == "CTRL+W"
    assert menu_item(groups, :close_tab).native_label == "Close Tab\tCTRL+W"
    assert menu_item(groups, :quit).native_label == "Quit\tCTRL+Q"
    assert menu_item(groups, :undo).native_label == "Undo\tCTRL+Z"
    assert menu_item(groups, :redo).native_label == "Redo\tCTRL+Y"
    assert menu_item(groups, :cut).native_label == "Cut\tCTRL+X"
    assert menu_item(groups, :copy).native_label == "Copy\tCTRL+C"
    assert menu_item(groups, :paste).native_label == "Paste\tCTRL+V"
    assert menu_item(groups, :select_all).native_label == "Select All\tCTRL+A"
    assert menu_item(groups, :find).native_label == "Find\tCTRL+F"
    assert menu_item(groups, :replace).native_label == "Replace\tCTRL+H"
    assert menu_item(groups, :edit_preferences).native_label == "Preferences\tCTRL+,"
    assert menu_item(groups, :view_posts).native_label == "Posts\tCTRL+1"
    assert menu_item(groups, :view_media).native_label == "Media\tCTRL+2"
    assert menu_item(groups, :toggle_sidebar).native_label == "Toggle Sidebar\tCTRL+B"
    assert menu_item(groups, :toggle_panel).native_label == "Toggle Panel\tCTRL+J"
    assert menu_item(groups, :toggle_assistant_sidebar).native_label == "Toggle Assistant Sidebar\tCTRL+\\"
    assert menu_item(groups, :publish_selected).native_label == "Publish Selected\tCTRL+SHIFT+P"
    assert menu_item(groups, :preview_post).native_label == "Preview Post\tCTRL+SHIFT+V"
    assert menu_item(groups, :generate_sitemap).native_label == "Generate Sitemap\tCTRL+R"
    assert menu_item(groups, :validate_site).native_label == "Validate Site\tCTRL+SHIFT+L"
    assert menu_item(groups, :upload_site).native_label == "Upload Site\tCTRL+SHIFT+U"
    assert menu_item(groups, :metadata_diff).shortcut == nil
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
    :ok = BDS.Tasks.clear_finished()

    assert {:ok, task} =
             BDS.Tasks.register_external_task("preview build", %{
               group_id: "generation",
               group_name: "Generation"
             })

    on_exit(fn ->
      _ = BDS.Tasks.complete_task(task.id)
      _ = BDS.Tasks.clear_finished()
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

  test "desktop router encodes failed task snapshots even when the task error is a tuple" do
    :ok = BDS.Tasks.clear_finished()

    assert {:ok, task} =
             BDS.Tasks.submit_task(
               "broken rebuild",
               fn _report ->
                 {:error, {{:badkey, "slug"}, [{BDS.Posts, :upsert_post_from_file, 3, [line: 644]}]}}
               end,
               %{group_id: "maintenance", group_name: "Maintenance"}
             )

    on_exit(fn ->
      _ = BDS.Tasks.clear_finished()
    end)

    failed = wait_for_task(task.id, &(&1.status == :failed and &1.error != nil))

    conn = conn(:get, "/api/tasks?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)

    assert Enum.any?(payload["tasks"], fn item ->
             item["id"] == failed.id and item["status"] == "failed" and is_binary(item["error"])
           end)

    assert Enum.any?(payload["tasks"], fn item ->
             item["id"] == failed.id and String.contains?(item["error"], "badkey")
           end)
  end

  test "desktop router exposes projects for shell project selection and creation" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    BDS.Repo.delete_all(BDS.Projects.Project)

    internal_projects_root = "/Users/gb/Projects/bDS2/priv/data/projects"
    before_internal_dirs =
      case File.ls(internal_projects_root) do
        {:ok, entries} -> MapSet.new(entries)
        {:error, :enoent} -> MapSet.new()
      end

    temp_dir = Path.join(System.tmp_dir!(), "bds-desktop-projects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Desktop Projects", data_path: temp_dir})
    {:ok, _active} = BDS.Projects.set_active_project(project.id)

    conn = conn(:get, "/api/projects?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)
    assert payload["active_project_id"] == project.id
    assert Enum.any?(payload["projects"], &(&1["id"] == project.id and &1["name"] == "Desktop Projects"))
    assert Enum.any?(payload["projects"], &(&1["id"] == "default" and &1["name"] == "My Blog"))

    created_data_dir = Path.join(temp_dir, "created-from-shell")
    create_conn =
      conn(
        :post,
        "/api/projects?k=#{Desktop.Auth.login_key()}",
        Jason.encode!(%{"name" => "Created From Shell", "data_path" => created_data_dir})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")

    create_conn = BDS.Desktop.Router.call(create_conn, BDS.Desktop.Router.init([]))

    assert create_conn.status == 200

    created_payload = Jason.decode!(create_conn.resp_body)
    assert created_payload["project"]["name"] == "Created From Shell"
    assert created_payload["active_project_id"] == created_payload["project"]["id"]
    assert created_payload["project"]["data_path"] == created_data_dir

    after_internal_dirs =
      case File.ls(internal_projects_root) do
        {:ok, entries} -> MapSet.new(entries)
        {:error, :enoent} -> MapSet.new()
      end

    assert after_internal_dirs == before_internal_dirs
  end

  test "desktop router lets the shell choose an existing project folder and reuses matching projects" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-desktop-existing-project-#{System.unique_integer([:positive])}")
    meta_dir = Path.join(temp_dir, "meta")
    File.mkdir_p!(meta_dir)

    File.write!(
      Path.join(meta_dir, "project.json"),
      Jason.encode!(%{"name" => "Existing Blog", "description" => "Imported from disk"})
    )

    {:ok, project} = BDS.Projects.create_project(%{name: "Existing Blog", data_path: temp_dir})

    previous_desktop = Application.get_env(:bds, :desktop, [])
    Application.put_env(:bds, :desktop, Keyword.put(previous_desktop, :folder_picker, TestFolderPicker))
    Process.put(:test_folder_picker_response, {:ok, temp_dir})

    on_exit(fn ->
      Application.put_env(:bds, :desktop, previous_desktop)
      Process.delete(:test_folder_picker_response)
      File.rm_rf(temp_dir)
    end)

    conn = conn(:post, "/api/project-folder?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Router.call(conn, BDS.Desktop.Router.init([]))

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)

    assert payload["status"] == "ok"
    assert payload["path"] == temp_dir
    assert payload["name"] == "Existing Blog"
    assert payload["description"] == "Imported from disk"
    assert payload["existing_project_id"] == project.id
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

  defp menu_item(groups, id) do
    groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&Map.get(&1, :id) == id)
  end

  defp wait_for_task(task_id, matcher, timeout \\ 2_000)

  defp wait_for_task(task_id, _matcher, timeout) when timeout <= 0 do
    BDS.Tasks.get_task(task_id)
  end

  defp wait_for_task(task_id, matcher, timeout) do
    task = BDS.Tasks.get_task(task_id)

    if task && matcher.(task) do
      task
    else
      Process.sleep(50)
      wait_for_task(task_id, matcher, timeout - 50)
    end
  end
end
