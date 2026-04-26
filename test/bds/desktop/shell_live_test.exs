defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.Persistence
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Tags

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir = Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Shell Project", data_path: temp_dir})
    {:ok, _project} = Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

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
    assert html =~ ~s(data-testid="panel-close")

    html =
      view
      |> element("[data-testid='panel-close']")
      |> render_click()

    assert html =~ ~s(class="panel-shell is-hidden")

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

  test "hiding the sidebar collapses its width to zero" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-shell")
    assert html =~ ~s(style="width: 280px;")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    assert html =~ ~s(class="sidebar-shell is-hidden")
    assert html =~ ~s(style="width: 0px;")
  end

  test "layout hooks sync persisted widths and apply drag resizing" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(style="width: 280px;")

    html = render_hook(view, "sync_layout", %{"sidebar_width" => 420, "assistant_sidebar_width" => 480})

    assert html =~ ~s(data-testid="sidebar-shell")
    assert html =~ ~s(style="width: 420px;")

    html =
      view
      |> element("[data-testid='toggle-assistant']")
      |> render_click()

    assert html =~ ~s(data-testid="assistant-shell")
    assert html =~ ~s(style="width: 480px;")

    html = render_hook(view, "resize_panel", %{"target" => "sidebar", "width" => 460})

    assert html =~ ~s(data-testid="sidebar-shell")
    assert html =~ ~s(style="width: 460px;")
  end

  test "sidebar filters and load more are server-driven", %{project: project} do
    seed_sidebar_posts(project.id)

    assert {:ok, _tag} = Tags.create_tag(%{project_id: project.id, name: "tech", color: "#112233"})

    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-search-form")
    assert html =~ ~s(data-testid="sidebar-filter-toggle")
    assert html =~ ~s(class="sidebar-section-header")
    assert html =~ ~s(class="sidebar-actions")
    assert html =~ ~s(data-testid="sidebar-load-more")
    assert html_position(html, ~s(data-testid="sidebar-load-more")) > html_position(html, ">Archived<")
    refute html =~ ~s(data-testid="sidebar-filter-tag")
    assert html =~ "Alpha Post"
    refute html =~ "Overflow Post"

    html =
      view
      |> element("[data-testid='sidebar-filter-toggle']")
      |> render_click()

    assert html =~ ~s(class="calendar-header collapsible-header collapsed")
    assert html =~ ~s(class="filter-header collapsible-header collapsed")
    refute html =~ ~s(class="calendar-year-header")
    refute html =~ ~s(data-testid="sidebar-filter-tag")

    html =
      view
      |> element("[data-testid='sidebar-filter-tags-header']")
      |> render_click()

    assert html =~ ~s(class="filter-chip has-color")
    assert html =~ ~s(data-testid="sidebar-filter-tag")

    html =
      view
      |> form("[data-testid='sidebar-search-form']", %{sidebar_filters: %{search: "Alpha"}})
      |> render_change()

    assert html =~ "Alpha Post"
    refute html =~ ~s(data-open-title="Beta Post")

    html =
      view
      |> element("[data-testid='sidebar-clear-search']")
      |> render_click()

    assert html =~ "Beta Post"

    html =
      view
      |> element("[data-testid='sidebar-filter-tag'][data-filter-tag='tech']")
      |> render_click()

    assert html =~ "Alpha Post"
    refute html =~ ~s(data-open-title="Beta Post")

    html =
      view
      |> element("[data-testid='sidebar-clear-filters']")
      |> render_click()

    assert html =~ "Beta Post"

    html =
      view
      |> element("[data-testid='sidebar-load-more']")
      |> render_click()

    assert html =~ "Overflow Post"
  end

  test "project switcher, ui language, dashboard recents, and output log are wired", %{temp_dir: temp_dir} do
    {:ok, other_project} = Projects.create_project(%{name: "Second Blog", data_path: Path.join(temp_dir, "second")})
    {:ok, recent_post} = Posts.create_post(%{project_id: other_project.id, title: "Recent Shell Post", content: "body"})

    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ "Shell Project"
    refute html =~ "Second Blog"

    html =
      view
      |> element("[data-testid='project-selector-trigger']")
      |> render_click()

    assert html =~ ~s(data-testid="project-dropdown")
    assert html =~ "Second Blog"

    html =
      view
      |> element("[data-testid='project-item'][data-project-id='#{other_project.id}']")
      |> render_click()

    assert html =~ "Second Blog"

    html =
      view
      |> form("[data-testid='status-language-form']", %{ui_language: "de"})
      |> render_change()

    assert html =~ "Beiträge durchsuchen..."

    html =
      view
      |> element("[data-testid='recent-post-item'][data-post-id='#{recent_post.id}']")
      |> render_click()

    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="#{recent_post.id}")
    assert html =~ "Recent Shell Post"

    html =
      render_click(view, "select_panel_tab", %{"tab" => "output"})

    assert html =~ "Activated Second Blog"
  end

  test "task button opens tasks and post panels render real link and git data", %{project: project, temp_dir: temp_dir} do
    {:ok, target} = Posts.create_post(%{project_id: project.id, title: "Target Post", content: "target body"})
    {:ok, target} = Posts.publish_post(target.id)
    target_href = canonical_post_href(target)

    {:ok, source} =
      Posts.create_post(%{project_id: project.id, title: "Linking Source", content: "See [Target](#{target_href})"})

    {:ok, source} = Posts.publish_post(source.id)
    :ok = Posts.rebuild_post_links(project.id)

    init_git_repo!(temp_dir, "Add published posts")

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => target.id,
        "title" => "Target Post",
        "subtitle" => "published"
      })

    assert html =~ "Target Post"

    html = render_click(view, "select_panel_tab", %{"tab" => "post_links"})

    assert html =~ "Backlinks"
    assert html =~ source.title

    html = render_click(view, "select_panel_tab", %{"tab" => "git_log"})

    assert html =~ "Add published posts"

    html = render_click(view, "select_panel_tab", %{"tab" => "output"})
    refute html =~ ~s(class="panel-shell is-hidden")

    html =
      view
      |> element("[data-testid='status-task-button']")
      |> render_click()

    refute html =~ ~s(class="panel-shell is-hidden")
    assert html =~ ~s(<button class="panel-tab active" type="button" phx-click="select_panel_tab" phx-value-tab="tasks">)
    assert html =~ ~s(class="task-list") or html =~ "No background tasks running"
  end

  defp seed_sidebar_posts(project_id) do
    now = Persistence.now_ms()

    entries =
      [
        sidebar_post(project_id, "alpha-post", "Alpha Post", now + 3_000, ["tech"], ["notes"]),
        sidebar_post(project_id, "beta-post", "Beta Post", now + 2_000, ["design"], ["guides"])
      ] ++
        Enum.map(1..498, fn index ->
          sidebar_post(project_id, "filler-#{index}", "Filler #{index}", now - index, ["filler"], ["archive"])
        end) ++
        [sidebar_post(project_id, "overflow-post", "Overflow Post", now - 10_000, ["tech"], ["notes"])]

    {count, _rows} = Repo.insert_all(Post, entries)
    assert count == length(entries)
  end

  defp html_position(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> -1
    end
  end

  defp sidebar_post(project_id, slug, title, timestamp, tags, categories) do
    %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      title: title,
      slug: slug,
      excerpt: nil,
      content: nil,
      status: :published,
      author: nil,
      created_at: timestamp,
      updated_at: timestamp,
      published_at: timestamp,
      file_path: "posts/#{slug}.md",
      checksum: nil,
      tags: tags,
      categories: categories,
      template_slug: nil,
      language: "en",
      do_not_translate: false,
      published_title: nil,
      published_content: nil,
      published_tags: nil,
      published_categories: nil,
      published_excerpt: nil
    }
  end

  defp canonical_post_href(post) do
    datetime = DateTime.from_unix!(post.created_at, :millisecond)

    Path.join([
      "",
      Integer.to_string(datetime.year),
      String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
      String.pad_leading(Integer.to_string(datetime.day), 2, "0"),
      post.slug,
      ""
    ])
  end

  defp init_git_repo!(project_dir, message) do
    run_git!(project_dir, ["init", "-b", "master"])
    run_git!(project_dir, ["config", "user.name", "bDS Tests"])
    run_git!(project_dir, ["config", "user.email", "tests@example.com"])
    run_git!(project_dir, ["add", "-A"])
    run_git!(project_dir, ["commit", "-m", message])
  end

  defp run_git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    assert status == 0, output
  end
end
