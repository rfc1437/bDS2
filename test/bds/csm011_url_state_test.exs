defmodule BDS.CSM011UrlStateTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    prev = System.get_env("BDS_DESKTOP_AUTOMATION")
    System.put_env("BDS_DESKTOP_AUTOMATION", "1")

    on_exit(fn ->
      if prev,
        do: System.put_env("BDS_DESKTOP_AUTOMATION", prev),
        else: System.delete_env("BDS_DESKTOP_AUTOMATION")
    end)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm011-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM011", data_path: temp_dir})
    {:ok, post} = BDS.Posts.create_post(%{project_id: project.id, title: "Test Post"})
    %{project: project, post: post}
  end

  describe "mount reads URL params" do
    test "/?view=media activates media view" do
      {:ok, view, _html} = live(build_conn(), "/?view=media")

      assert get_workbench(view).active_view == :media
    end

    test "/ defaults to posts view" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert get_workbench(view).active_view == :posts
    end

    test "invalid view param falls back to posts" do
      {:ok, view, _html} = live(build_conn(), "/?view=nonexistent")

      assert get_workbench(view).active_view == :posts
    end

    test "/?tab=post:<id> opens the tab", %{post: post} do
      {:ok, view, _html} = live(build_conn(), "/?tab=post:#{post.id}")

      assert get_workbench(view).active_tab == {:post, post.id}
    end

    test "/?view=media&tab=post:<id> applies both", %{post: post} do
      {:ok, view, _html} = live(build_conn(), "/?view=media&tab=post:#{post.id}")

      workbench = get_workbench(view)
      assert workbench.active_view == :media
      assert workbench.active_tab == {:post, post.id}
    end
  end

  describe "select_view pushes url-state event" do
    test "selecting media view pushes url with view=media" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_view", %{"view" => "media"})

      assert_push_event(view, "url-state", %{path: "/?view=media"})
    end

    test "selecting posts view pushes clean URL" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_view", %{"view" => "posts"})

      assert_push_event(view, "url-state", %{path: "/"})
    end
  end

  describe "select_tab pushes url-state event" do
    test "selecting a tab pushes URL with tab param", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_tab", %{"type" => "post", "id" => post.id})

      assert_push_event(view, "url-state", %{path: path})
      assert path =~ "tab=post"
      assert path =~ post.id
    end
  end

  describe "close_tab pushes url-state event" do
    test "closing the active tab removes tab from URL", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_tab", %{"type" => "post", "id" => post.id})
      render_click(view, "close_tab", %{"type" => "post", "id" => post.id})

      assert_push_event(view, "url-state", %{path: "/"})
    end
  end

  describe "open_sidebar_item pushes url-state event" do
    test "opening a sidebar item pushes URL with tab param", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "open_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => "Test Post"
      })

      assert_push_event(view, "url-state", %{path: path})
      assert path =~ "tab=post"
      assert path =~ post.id
    end
  end

  defp get_workbench(view) do
    state = :sys.get_state(view.pid)
    state.socket.assigns.workbench
  end
end
