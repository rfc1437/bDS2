defmodule BDS.DesktopTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Desktop.Wx

  require Record

  Record.defrecordp(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))

  defmodule FakeShutdown do
    def request_quit do
      send(Application.fetch_env!(:bds, :desktop_shutdown_test_pid), :quit_requested)
      :ok
    end
  end

  defmodule FakeWindowQuit do
    def quit do
      send(Application.fetch_env!(:bds, :desktop_shutdown_test_pid), :window_quit_requested)
      :ok
    end
  end

  defmodule FakeWindowLifecycle do
    def hide(window_id) do
      send(Application.fetch_env!(:bds, :desktop_shutdown_test_pid), {:window_hide_requested, window_id})
      :ok
    end

    def quit do
      send(Application.fetch_env!(:bds, :desktop_shutdown_test_pid), :window_quit_requested)
      :ok
    end
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

    assert menu_item(groups, :toggle_assistant_sidebar).native_label ==
             "Toggle Assistant Sidebar\tCTRL+\\"

    assert menu_item(groups, :publish_selected).native_label == "Publish Selected\tCTRL+SHIFT+P"
    assert menu_item(groups, :preview_post).native_label == "Preview Post\tCTRL+SHIFT+V"
    assert menu_item(groups, :generate_sitemap).native_label == "Generate Site\tCTRL+R"
    assert menu_item(groups, :validate_site).native_label == "Validate Site\tCTRL+SHIFT+L"
    assert menu_item(groups, :upload_site).native_label == "Upload Site\tCTRL+SHIFT+U"
    assert menu_item(groups, :metadata_diff).shortcut == nil
  end

  test "prod forwarded menu surface is covered by the shell dispatcher except unresolved filler action" do
    forwarded_actions =
      BDS.Desktop.MenuBar.groups(dev_mode?: false)
      |> Enum.flat_map(fn group ->
        group.items
        |> Enum.reject(&Map.get(&1, :separator, false))
        |> Enum.map(& &1.id)
      end)
      |> MapSet.new()

    unsupported_actions =
      forwarded_actions
      |> MapSet.difference(BDS.Desktop.ShellLive.supported_menu_actions())
      |> Enum.sort()

    assert unsupported_actions == [:fill_missing_translations]
  end

  test "native menu quit requests app-owned shutdown" do
    previous_module = Application.get_env(:bds, :desktop_shutdown_module)
    previous_pid = Application.get_env(:bds, :desktop_shutdown_test_pid)

    Application.put_env(:bds, :desktop_shutdown_module, FakeShutdown)
    Application.put_env(:bds, :desktop_shutdown_test_pid, self())

    on_exit(fn ->
      restore_env(:desktop_shutdown_module, previous_module)
      restore_env(:desktop_shutdown_test_pid, previous_pid)
    end)

    assert {:noreply, %{}} = BDS.Desktop.MenuBar.handle_event("quit", %{})
    assert_receive :quit_requested
  end

  test "icon menu quit requests app-owned shutdown" do
    previous_module = Application.get_env(:bds, :desktop_shutdown_module)
    previous_pid = Application.get_env(:bds, :desktop_shutdown_test_pid)

    Application.put_env(:bds, :desktop_shutdown_module, FakeShutdown)
    Application.put_env(:bds, :desktop_shutdown_test_pid, self())

    on_exit(fn ->
      restore_env(:desktop_shutdown_module, previous_module)
      restore_env(:desktop_shutdown_test_pid, previous_pid)
    end)

    assert {:noreply, %{}} = BDS.Desktop.Menu.handle_event("quit", %{})
    assert_receive :quit_requested
  end

  test "cmd-q is handled by the app-owned shutdown handler" do
    assert {:module, BDS.Desktop.Shutdown} = Code.ensure_loaded(BDS.Desktop.Shutdown)
    assert function_exported?(BDS.Desktop.Shutdown, :command_menu_selected, 2)
  end

  test "cmd-q callback requests app-owned shutdown" do
    previous_module = Application.get_env(:bds, :desktop_shutdown_module)
    previous_pid = Application.get_env(:bds, :desktop_shutdown_test_pid)

    Application.put_env(:bds, :desktop_shutdown_module, FakeShutdown)
    Application.put_env(:bds, :desktop_shutdown_test_pid, self())

    on_exit(fn ->
      restore_env(:desktop_shutdown_module, previous_module)
      restore_env(:desktop_shutdown_test_pid, previous_pid)
    end)

    assert :ok = BDS.Desktop.Shutdown.command_menu_selected(wx(id: Wx.wxID_EXIT()), nil)
    assert_receive :quit_requested
  end

  test "app-owned shutdown delegates final termination to the desktop hard quit path" do
    previous_module = Application.get_env(:bds, :desktop_shutdown_module)
    previous_quit_module = Application.get_env(:bds, :desktop_window_quit_module)
    previous_pid = Application.get_env(:bds, :desktop_shutdown_test_pid)

    Application.put_env(:bds, :desktop_shutdown_module, BDS.Desktop.Shutdown)
    Application.put_env(:bds, :desktop_window_quit_module, FakeWindowQuit)
    Application.put_env(:bds, :desktop_shutdown_test_pid, self())

    on_exit(fn ->
      restore_env(:desktop_shutdown_module, previous_module)
      restore_env(:desktop_window_quit_module, previous_quit_module)
      restore_env(:desktop_shutdown_test_pid, previous_pid)
    end)

    assert :ok = BDS.Desktop.Shutdown.request_quit()
    assert_receive :window_quit_requested
  end

  test "app-owned shutdown hides the window before hard quit" do
    previous_module = Application.get_env(:bds, :desktop_shutdown_module)
    previous_quit_module = Application.get_env(:bds, :desktop_window_quit_module)
    previous_window_module = Application.get_env(:bds, :desktop_window_module)
    previous_pid = Application.get_env(:bds, :desktop_shutdown_test_pid)

    Application.put_env(:bds, :desktop_shutdown_module, BDS.Desktop.Shutdown)
    Application.put_env(:bds, :desktop_window_quit_module, FakeWindowLifecycle)
    Application.put_env(:bds, :desktop_window_module, FakeWindowLifecycle)
    Application.put_env(:bds, :desktop_shutdown_test_pid, self())
    expected_window_id = BDS.Desktop.MainWindow.window_id()

    on_exit(fn ->
      restore_env(:desktop_shutdown_module, previous_module)
      restore_env(:desktop_window_quit_module, previous_quit_module)
      restore_env(:desktop_window_module, previous_window_module)
      restore_env(:desktop_shutdown_test_pid, previous_pid)
    end)

    assert :ok = BDS.Desktop.Shutdown.request_quit()
    assert_receive {:window_hide_requested, ^expected_window_id}
    assert_receive :window_quit_requested
  end

  test "desktop root html is a LiveView shell and references only the live bootstrap assets" do
    conn = conn(:get, "/?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Endpoint.call(conn, BDS.Desktop.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ ~s(class="app")
    refute conn.resp_body =~ ~s(data-testid="window-titlebar")
    refute conn.resp_body =~ ~s(data-testid="window-titlebar-menu-bar")
    assert conn.resp_body =~ ~s(data-testid="status-shell-controls")
    assert conn.resp_body =~ ~s(data-testid="toggle-sidebar")
    assert conn.resp_body =~ ~s(data-testid="toggle-panel")
    assert conn.resp_body =~ ~s(data-testid="toggle-assistant")
    assert conn.resp_body =~ ~s(class="activity-bar")
    assert conn.resp_body =~ ~s(class="sidebar")
    assert conn.resp_body =~ ~s(class="status-bar")
    assert conn.resp_body =~ ~s(data-phx-main)
    assert conn.resp_body =~ ~s(src="/assets/live.js")
    assert conn.resp_body =~ ~s(href="/assets/app.css")
    refute conn.resp_body =~ ~s(src="/assets/app.js")
  end

  test "desktop endpoint serves the live shell without extra router-side secret injection" do
    conn = conn(:get, "/?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Endpoint.call(conn, BDS.Desktop.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ ~s(data-phx-main)
  end

  test "desktop endpoint exposes a simple health route" do
    conn = conn(:get, "/health?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Endpoint.call(conn, BDS.Desktop.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "desktop endpoint serves active-project media thumbnails for the live sidebar" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-desktop-thumbnail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf(temp_dir)
    end)

    {:ok, project} =
      BDS.Projects.create_project(%{name: "Desktop Thumbnails", data_path: temp_dir})

    {:ok, _active} = BDS.Projects.set_active_project(project.id)

    source_path = Path.join(temp_dir, "sample.jpg")
    File.write!(source_path, tiny_jpeg_binary())

    assert {:ok, media} =
             BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    conn = conn(:get, "/media-thumbnail/#{media.id}?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Endpoint.call(conn, BDS.Desktop.Endpoint.init([]))

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "image/webp")
    assert byte_size(conn.resp_body) > 0
  end

  defp menu_item(groups, id) do
    groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&(Map.get(&1, :id) == id))
  end

  defp tiny_jpeg_binary do
    Image.new!(3, 2, color: [255, 0, 0])
    |> Image.write!(:memory, suffix: ".jpg", quality: 85)
  end

  defp restore_env(key, nil), do: Application.delete_env(:bds, key)
  defp restore_env(key, value), do: Application.put_env(:bds, key, value)
end
