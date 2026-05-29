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
      send(
        Application.fetch_env!(:bds, :desktop_shutdown_test_pid),
        {:window_hide_requested, window_id}
      )

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

  test "prod forwarded menu surface is covered by the shell dispatcher" do
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

    assert unsupported_actions == []
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

  test "desktop external links point at the bDS2 GitHub project and issue tracker" do
    assert BDS.Desktop.ExternalLinks.github_url() == "https://github.com/rfc1437/bDS2"

    assert BDS.Desktop.ExternalLinks.github_issues_url() ==
             "https://github.com/rfc1437/bDS2/issues"
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

  test "the app owns final termination instead of delegating to Desktop.Window/System.halt" do
    # Desktop.Window.quit/0 routes through System.halt/1, which runs the wx C++
    # static destructors on exit and crashes on macOS. The app-owned shutdown
    # must terminate the OS process directly with SIGKILL instead.
    assert BDS.Desktop.Shutdown.quit_module() == BDS.Desktop.Shutdown
  end

  test "hard quit terminates the BEAM OS process with SIGKILL rather than libc exit" do
    previous_kill = Application.get_env(:bds, :desktop_os_kill_fun)
    test_pid = self()

    Application.put_env(:bds, :desktop_os_kill_fun, fn os_pid ->
      send(test_pid, {:os_killed, to_string(os_pid)})
      :ok
    end)

    on_exit(fn -> restore_env(:desktop_os_kill_fun, previous_kill) end)

    assert :ok = BDS.Desktop.Shutdown.quit()
    assert_receive {:os_killed, beam_pid}
    assert beam_pid == to_string(:os.getpid())
  end

  test "hard quit kills heart before itself so the app is not relaunched" do
    previous_kill = Application.get_env(:bds, :desktop_os_kill_fun)
    test_pid = self()

    {:ok, fake_heart} =
      Agent.start(fn -> :ok end, name: :heart)

    Application.put_env(:bds, :desktop_os_kill_fun, fn os_pid ->
      send(test_pid, {:os_killed, to_string(os_pid)})
      :ok
    end)

    on_exit(fn ->
      restore_env(:desktop_os_kill_fun, previous_kill)
      if Process.alive?(fake_heart), do: Agent.stop(fake_heart)
    end)

    assert :ok = BDS.Desktop.Shutdown.quit()
    # heart has no linked port here, so only the BEAM itself is killed, and the
    # call must not crash while inspecting the heart process.
    assert_receive {:os_killed, beam_pid}
    assert beam_pid == to_string(:os.getpid())
  end

  test "desktop root html is a LiveView shell and references the generated asset entrypoints" do
    conn = conn(:get, "/?k=#{Desktop.Auth.login_key()}")
    conn = BDS.Desktop.Endpoint.call(conn, BDS.Desktop.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ ~s(class="app flex h-full w-full flex-col")
    refute conn.resp_body =~ ~s(data-testid="window-titlebar")
    refute conn.resp_body =~ ~s(data-testid="window-titlebar-menu-bar")
    assert conn.resp_body =~ ~s(data-testid="status-shell-controls")
    assert conn.resp_body =~ ~s(data-testid="toggle-sidebar")
    assert conn.resp_body =~ ~s(data-testid="toggle-panel")
    assert conn.resp_body =~ ~s(data-testid="toggle-assistant")
    assert conn.resp_body =~ ~s(class="activity-bar flex h-full shrink-0 flex-col items-center justify-between")
    assert conn.resp_body =~ ~s(class="sidebar flex min-w-0 flex-1 overflow-hidden")
    assert conn.resp_body =~ ~s(class="status-bar flex h-[22px] shrink-0 items-center justify-between gap-2")
    assert conn.resp_body =~ ~s(data-phx-main)
    assert conn.resp_body =~ ~s(href="/assets/app.css")
    assert conn.resp_body =~ ~s(src="/assets/app.js")
    refute conn.resp_body =~ ~s(src="/assets/live.js")
    refute conn.resp_body =~ ~s(src="/vendor/phoenix/phoenix.min.js")
    refute conn.resp_body =~ ~s(src="/vendor/live_view/phoenix_live_view.min.js")
  end

  test "desktop endpoint serves generated Phoenix-style CSS and JS assets" do
    css_conn = conn(:get, "/assets/app.css?k=#{Desktop.Auth.login_key()}")
    css_conn = BDS.Desktop.Endpoint.call(css_conn, BDS.Desktop.Endpoint.init([]))

    js_conn = conn(:get, "/assets/app.js?k=#{Desktop.Auth.login_key()}")
    js_conn = BDS.Desktop.Endpoint.call(js_conn, BDS.Desktop.Endpoint.init([]))

    assert css_conn.status == 200
    assert byte_size(css_conn.resp_body) > 0
    assert js_conn.status == 200
    assert byte_size(js_conn.resp_body) > 0
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
