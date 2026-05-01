defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @shell_live_source_root Path.expand("../../../lib/bds/desktop/shell_live", __DIR__)

  test "shell live modules use contexts instead of direct Repo.get calls" do
    source_files =
      [
        Path.expand("../../../lib/bds/desktop/shell_live.ex", __DIR__)
        | Path.wildcard(Path.join(@shell_live_source_root, "**/*.ex"))
      ]

    offenders =
      source_files
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} ->
          String.contains?(line, "Repo.get(") or String.contains?(line, "Repo.get!(")
        end)
        |> Enum.map(fn {_line, line_number} -> "#{Path.relative_to_cwd(path)}:#{line_number}" end)
      end)

    assert offenders == []
  end

  alias BDS.Persistence
  alias BDS.AI
  alias BDS.CliSync.Watcher
  alias BDS.Menu
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts
  alias BDS.Templates
  alias BDS.Tags
  alias BDS.ImportDefinitions
  alias BDS.UI.{Session, Workbench}

  defmodule FakeEndpointModelHttpClient do
    def get("https://api.example.test/v1/models", _headers) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: Jason.encode!(%{"data" => [%{"id" => "gpt-4.1"}, %{"id" => "gpt-4.1-mini"}]})
       }}
    end

    def get("http://localhost:11434/v1/models", _headers) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: Jason.encode!(%{"data" => [%{"id" => "llama3.3"}, %{"id" => "llava:latest"}]})
       }}
    end

    def get(_url, _headers), do: {:error, :not_found}
  end

  defmodule DelayedChatServer do
    use Plug.Router
    import Phoenix.ConnTest, except: [post: 2]

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      Process.sleep(300)

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "Delayed **response**"}}],
          "usage" => %{"prompt_tokens" => 8, "completion_tokens" => 5}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Shell Project", data_path: temp_dir})
    {:ok, _project} = Projects.set_active_project(project.id)

    original_shell_platform = Application.get_env(:bds, :shell_platform)
    original_git_remote_state_provider = Application.get_env(:bds, :git_remote_state_provider)
    original_ai_http_client = Application.get_env(:bds, :ai_http_client)

    on_exit(fn ->
      if is_nil(original_shell_platform) do
        Application.delete_env(:bds, :shell_platform)
      else
        Application.put_env(:bds, :shell_platform, original_shell_platform)
      end

      if is_nil(original_git_remote_state_provider) do
        Application.delete_env(:bds, :git_remote_state_provider)
      else
        Application.put_env(:bds, :git_remote_state_provider, original_git_remote_state_provider)
      end

      if is_nil(original_ai_http_client) do
        Application.delete_env(:bds, :ai_http_client)
      else
        Application.put_env(:bds, :ai_http_client, original_ai_http_client)
      end
    end)

    %{project: project, temp_dir: temp_dir}
  end

  test "sidebar headers expose old-app create actions for posts, media, scripts, templates, chat, and imports" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-create-action")
    assert html =~ ~s(data-sidebar-action="post")
    assert html =~ ~s(data-testid="sidebar-filter-toggle")

    html = render_click(view, "select_view", %{"view" => "media"})

    assert html =~ ~s(data-sidebar-action="media")
    assert html =~ ~s(data-testid="sidebar-filter-toggle")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='scripts']")
      |> render_click()

    assert html =~ ~s(data-sidebar-action="script")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='templates']")
      |> render_click()

    assert html =~ ~s(data-sidebar-action="template")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='chat']")
      |> render_click()

    assert html =~ ~s(data-sidebar-action="chat")

    html =
      view
      |> element("[data-testid='activity-button'][data-view='import']")
      |> render_click()

    assert html =~ ~s(data-sidebar-action="import")
  end

  test "sidebar create actions follow the old-app post, script, template, chat, and import flows",
       %{
         project: project
       } do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
    post_count_before = Repo.aggregate(Post, :count, :id)
    script_count_before = Repo.aggregate(BDS.Scripts.Script, :count, :id)
    template_count_before = Repo.aggregate(BDS.Templates.Template, :count, :id)
    chat_count_before = Repo.aggregate(BDS.AI.ChatConversation, :count, :id)
    import_count_before = Repo.aggregate(ImportDefinitions.ImportDefinition, :count, :id)

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='post']")
      |> render_click()

    assert Repo.aggregate(Post, :count, :id) == post_count_before + 1

    created_post = Repo.one!(Post)
    assert created_post.project_id == project.id
    assert created_post.title == ""
    assert created_post.content == ""
    refute html =~ ~s(data-tab-type="post")

    _html = render_click(view, "select_view", %{"view" => "scripts"})

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='script']")
      |> render_click()

    assert Repo.aggregate(BDS.Scripts.Script, :count, :id) == script_count_before + 1

    created_script = Repo.one!(BDS.Scripts.Script)
    assert created_script.project_id == project.id
    assert created_script.title == "New Script"
    assert created_script.entrypoint == "main"
    assert created_script.content == "print(\"new script\")"
    assert html =~ ~s(data-tab-type="scripts")
    assert html =~ ~s(data-tab-id="#{created_script.id}")

    _html = render_click(view, "select_view", %{"view" => "templates"})

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='template']")
      |> render_click()

    assert Repo.aggregate(BDS.Templates.Template, :count, :id) == template_count_before + 1

    created_template = Repo.get_by!(BDS.Templates.Template, title: "New Template")
    assert created_template.project_id == project.id
    assert created_template.title == "New Template"
    assert created_template.content == ""
    assert html =~ ~s(data-tab-type="templates")
    assert html =~ ~s(data-tab-id="#{created_template.id}")

    _html = render_click(view, "select_view", %{"view" => "chat"})

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='chat']")
      |> render_click()

    assert Repo.aggregate(BDS.AI.ChatConversation, :count, :id) == chat_count_before + 1

    created_chat = Repo.one!(BDS.AI.ChatConversation)
    assert created_chat.title == "New Chat"
    assert html =~ ~s(data-tab-type="chat")
    assert html =~ ~s(data-tab-id="#{created_chat.id}")

    html = render_click(view, "select_view", %{"view" => "chat"})
    assert html =~ ~s(data-testid="sidebar-delete-chat")

    html =
      view
      |> element("[data-testid='sidebar-delete-chat'][data-item-id='#{created_chat.id}']")
      |> render_click()

    refute Repo.get(BDS.AI.ChatConversation, created_chat.id)
    refute html =~ ~s(data-tab-id="#{created_chat.id}")

    _html = render_click(view, "select_view", %{"view" => "import"})

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='import']")
      |> render_click()

    assert Repo.aggregate(ImportDefinitions.ImportDefinition, :count, :id) ==
             import_count_before + 1

    created_definition = Repo.one!(ImportDefinitions.ImportDefinition)
    assert created_definition.project_id == project.id
    assert created_definition.name == "New Import Definition"
    assert html =~ ~s(data-tab-type="import")
    assert html =~ ~s(data-tab-id="#{created_definition.id}")
  end

  test "settings sidebar selections expose a scroll target for the preferences editor" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_click(view, "select_view", %{"view" => "settings"})

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='settings-ai']")
      |> render_click()

    assert html =~ ~s(phx-hook="SettingsSectionScroll")
    assert html =~ ~s(data-selected-settings-section="ai")
    assert html =~ ~s(data-settings-scroll-target="settings-section-ai")
  end

  test "shell live refreshes the posts sidebar when the CLI watcher broadcasts an entity change",
       %{project: project} do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    refute html =~ "CLI Added Post"

    assert {:ok, post} = Posts.create_post(%{project_id: project.id, title: "CLI Added Post"})

    Phoenix.PubSub.broadcast(
      BDS.PubSub,
      Watcher.topic(),
      {:entity_changed, %{entity: "post", entity_id: post.id, action: :created}}
    )

    assert render(view) =~ "CLI Added Post"
  end

  test "shell live closes stale post and media tabs when the CLI watcher broadcasts deletions", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} = Posts.create_post(%{project_id: project.id, title: "CLI Delete Post"})

    source_path = Path.join(temp_dir, "cli-delete-media.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "CLI Delete Media"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='#{post.id}']")
      |> render_click()

    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="#{post.id}")

    assert {:ok, :deleted} = Posts.delete_post(post.id)

    Phoenix.PubSub.broadcast(
      BDS.PubSub,
      Watcher.topic(),
      {:entity_changed, %{entity: "post", entity_id: post.id, action: :deleted}}
    )

    html = render(view)
    refute html =~ ~s(data-tab-type="post")
    refute html =~ "CLI Delete Post"

    _html =
      view
      |> element("[data-testid='activity-button'][data-view='media']")
      |> render_click()

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='#{media.id}']")
      |> render_click()

    assert html =~ ~s(data-tab-type="media")
    assert html =~ ~s(data-tab-id="#{media.id}")

    assert {:ok, :deleted} = Media.delete_media(media.id)

    Phoenix.PubSub.broadcast(
      BDS.PubSub,
      Watcher.topic(),
      {:entity_changed, %{entity: "media", entity_id: media.id, action: :deleted}}
    )

    html = render(view)
    refute html =~ ~s(data-tab-type="media")
    refute html =~ "CLI Delete Media"
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

    html = render_click(view, "select_view", %{"view" => "templates"})

    assert html =~ ~s(data-view="templates")
    assert html =~ ~s(data-active="true")
    assert html =~ ~s(aria-label="Templates")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    assert html =~ ~s(class="sidebar-shell is-hidden")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    refute html =~ ~s(class="sidebar-shell is-hidden")

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

    settings_html =
      view
      |> element("[data-testid='activity-button'][data-view='settings']")
      |> render_click()

    assert settings_html =~ ~s(data-testid="sidebar-open-item")

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

  test "macos hides the custom titlebar and moves shell toggles into the status bar" do
    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    refute html =~ ~s(data-testid="window-titlebar")
    refute html =~ ~s(data-testid="window-titlebar-menu-bar")
    refute html =~ ~s(data-testid="window-titlebar-menu-button")
    refute html =~ ~s(data-testid="window-titlebar-menu-dropdown")
    assert html =~ ~s(data-testid="status-shell-controls")
    assert html =~ ~s(data-testid="toggle-sidebar")
    assert html =~ ~s(data-testid="toggle-panel")
    assert html =~ ~s(data-testid="toggle-assistant")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    assert html =~ ~s(class="sidebar-shell is-hidden")

    html =
      render_hook(view, "native_menu_action", %{"action" => "edit_preferences"})

    assert html =~ ~s(data-tab-type="settings")
    assert html =~ ">Settings<"
  end

  test "titlebar menu matches the old shell contract on windows and linux" do
    Application.put_env(:bds, :shell_platform, {:unix, :linux})

    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    refute html =~ ~s(class="window-titlebar is-mac")
    assert html =~ ~s(data-testid="window-titlebar-menu-bar")
    assert html =~ ~s(data-testid="window-titlebar-menu-button")
    assert html =~ ~s(data-menu-group="file")
    assert html =~ ~s(>File<)

    html =
      view
      |> element("[data-testid='window-titlebar-menu-button'][data-menu-group='file']")
      |> render_click()

    assert html =~ ~s(data-testid="window-titlebar-menu-dropdown")
    assert html =~ ~s(data-testid="window-titlebar-menu-item")
    assert html =~ ~s(data-menu-action="new_post")
    assert html =~ ~s(>New Post<)

    html =
      view
      |> element("[data-testid='window-titlebar-menu-button'][data-menu-group='edit']")
      |> render_click()

    assert html =~ ~s(data-menu-action="edit_preferences")

    html =
      view
      |> element("[data-testid='window-titlebar-menu-item'][data-menu-action='edit_preferences']")
      |> render_click()

    assert html =~ ~s(data-tab-type="settings")
    assert html =~ ">Settings<"
    refute html =~ ~s(data-testid="window-titlebar-menu-dropdown")
  end

  test "titlebar menu keyboard navigation is owned by liveview on windows and linux" do
    Application.put_env(:bds, :shell_platform, {:unix, :linux})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='window-titlebar-menu-button'][data-menu-group='file']")
      |> render_click()

    assert html =~ ~s(data-open-menu-group="file")

    html = render_keydown(view, "titlebar_menu_keydown", %{key: "ArrowRight"})

    assert html =~ ~s(data-open-menu-group="edit")
    assert html =~ ~s(data-menu-action="edit_preferences")

    html = render_keydown(view, "titlebar_menu_keydown", %{key: "End"})

    assert html =~ ~s(class="window-titlebar-menu-item is-keyboard-active")
    assert html =~ ~s(data-menu-action="edit_preferences")

    html = render_keydown(view, "titlebar_menu_keydown", %{key: "Enter"})

    assert html =~ ~s(data-tab-type="settings")
    assert html =~ ">Settings<"
    refute html =~ ~s(data-testid="window-titlebar-menu-dropdown")
  end

  test "native edit menu action opens the dedicated menu editor surface", %{project: project} do
    assert {:ok, _menu} =
             Menu.update_menu(project.id, [
               %{kind: :page, label: "About", slug: "about"},
               %{
                 kind: :submenu,
                 label: "Sections",
                 children: [
                   %{kind: :page, label: "Contact", slug: "contact"}
                 ]
               }
             ])

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html = render_hook(view, "native_menu_action", %{"action" => "edit_menu"})

    assert html =~ ~s(data-testid="menu-editor")
    assert html =~ "Blog Menu Editor"
    assert html =~ "meta/menu.opml"
    assert html =~ ~s(data-testid="menu-editor-toolbar")
    assert html =~ ~s(data-testid="menu-editor-toolbar-button")
    assert html =~ ~s(data-action="add-entry")
    assert html =~ ~s(data-action="save")
    assert html =~ ~s(data-action="indent")
    assert html =~ ~s(data-action="unindent")
    assert html =~ ~s(data-testid="menu-editor-row")
    assert html =~ ~s(data-menu-label="Home")
    assert html =~ ~s(data-menu-label="About")
    assert html =~ ~s(data-menu-label="Sections")
    refute html =~ "Desktop workbench content routed through the Elixir shell."
  end

  test "menu editor adds a submenu, nests an entry, and saves the opml", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _menu} =
             Menu.update_menu(project.id, [
               %{kind: :page, label: "Contact", slug: "contact"}
             ])

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
    _html = render_hook(view, "native_menu_action", %{"action" => "edit_menu"})

    html =
      view
      |> element("[data-testid='menu-editor-toolbar-button'][data-action='add-entry']")
      |> render_click()

    assert html =~ ~s(data-testid="menu-editor-entry-form")

    html =
      view
      |> form("[data-testid='menu-editor-entry-form']", %{
        menu_editor_entry: %{"query" => "Sections"}
      })
      |> render_change()

    assert html =~ ~s(value="Sections")

    html =
      view
      |> form("[data-testid='menu-editor-entry-form']", %{
        menu_editor_entry: %{"query" => "Sections"}
      })
      |> render_submit()

    assert html =~ ~s(data-menu-label="Sections")

    html =
      view
      |> element("[data-testid='menu-editor-row'][data-menu-label='Contact']")
      |> render_click()

    assert html =~ ~s(data-selected="true")

    _html =
      view
      |> element("[data-testid='menu-editor-toolbar-button'][data-action='indent']")
      |> render_click()

    _html =
      view
      |> element("[data-testid='menu-editor-toolbar-button'][data-action='save']")
      |> render_click()

    assert {:ok, menu} = Menu.get_menu(project.id)

    assert menu.items == [
             %{kind: :home, label: "Home", slug: nil},
             %{
               kind: :submenu,
               label: "Sections",
               slug: nil,
               children: [
                 %{kind: :page, label: "Contact", slug: "contact"}
               ]
             }
           ]

    opml_path = Path.join([temp_dir, "meta", "menu.opml"])
    contents = File.read!(opml_path)

    assert contents =~ ~s(<outline text="Sections" type="submenu">)
    assert contents =~ ~s(<outline text="Contact" type="page" pageSlug="contact")
  end

  test "workbench session restore reopens permanent and transient tabs and selected activity" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.click_activity(:media)
      |> Workbench.open_tab(:post, "post-1", :pin)
      |> Workbench.open_tab(:media, "media-1", :preview)
      |> Session.serialize()

    html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})

    assert html =~ ~s(data-view="media")
    assert html =~ ~s(data-active="true")
    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="post-1")
    assert html =~ ~s(data-tab-type="media")
    assert html =~ ~s(data-tab-id="media-1")
    assert html =~ ~s(class="tab active transient")
  end

  test "metadata diff refresh reruns after workbench session restore", %{project: project} do
    :ok = BDS.Tasks.clear_finished()

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.open_tab(:metadata_diff, "metadata_diff", :pin)
      |> Session.serialize()

    html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})
    assert html =~ ~s(data-tab-type="metadata_diff")

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    _html =
      view
      |> element("button[phx-click='rerun_misc_editor']")
      |> render_click()

    refresh_task = new_task!(existing_ids, "Metadata Diff")
    assert refresh_task.group_name == "Maintenance"
    completed_task!(refresh_task.id)
    send(view.pid, :refresh_task_status)

    assert render(view) =~ project.name
  end

  test "shell live renders the legacy git activity badge from remote behind count" do
    Application.put_env(:bds, :git_remote_state_provider, fn _project_id, _opts ->
      {:ok,
       %{
         local_branch: "main",
         upstream_branch: "origin/main",
         has_upstream: true,
         ahead: 0,
         behind: 7
       }}
    end)

    {:ok, _view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-view="git")
    assert html =~ ~s(class="activity-bar-badge")
    assert html =~ ">7<"
  end

  test "assistant sidebar exposes context, prompt, and offline-gated transcript" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='toggle-assistant']")
      |> render_click()

    assert html =~ ~s(data-testid="assistant-shell")
    assert html =~ ~s(data-testid="assistant-context")
    assert html =~ ~s(data-testid="assistant-prompt-form")
    assert html =~ ~s(data-testid="assistant-prompt-input")
    assert html =~ ~s(data-testid="assistant-start-button")
    assert html =~ ~s(>Dashboard<)

    html =
      render_submit(view, "submit_assistant_prompt", %{
        "assistant" => %{"prompt" => "Summarize the current project"}
      })

    assert html =~ ~s(data-testid="assistant-message-user")
    assert html =~ ~s(data-testid="assistant-message-assistant")
    assert html =~ "Summarize the current project"
    assert html =~ "Automatic AI actions stay gated by airplane mode."
  end

  test "ai settings expose two openai-compatible endpoints and clear legacy mistral config" do
    assert {:ok, _endpoint} =
             AI.put_endpoint(:mistral, %{
               url: "https://legacy.example.test/v1",
               api_key: "legacy-secret",
               model: "legacy-model"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      view
      |> element("[data-testid='activity-button'][data-view='settings']")
      |> render_click()

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='settings-project']")
      |> render_click()

    assert html =~ "AI"
    assert html =~ "Online Endpoint URL"
    assert html =~ "Offline Endpoint URL"
    assert html =~ "Online API Key"
    assert html =~ "Offline API Key"
    refute html =~ "Mistral API Key"
    refute html =~ "Anthropic / Online API Key"

    _html =
      render_change(view, "change_settings_ai", %{
        "settings_ai" => %{
          "online_url" => "https://api.example.test/v1",
          "online_api_key" => "online-secret",
          "online_chat_model" => "gpt-4.1",
          "online_chat_tools" => "true",
          "online_title_model" => "gpt-4.1-mini",
          "online_image_analysis_model" => "gpt-4.1-vision",
          "offline_url" => "http://localhost:11434/v1",
          "offline_api_key" => "",
          "offline_chat_model" => "llama3.3",
          "offline_chat_tools" => "true",
          "offline_title_model" => "llama3.2",
          "offline_image_analysis_model" => "llava:latest",
          "offline_mode" => "true",
          "system_prompt" => "You are the local test prompt."
        }
      })

    _html = render_click(view, "save_settings_ai")

    assert {:ok, online_endpoint} = AI.get_endpoint(:online)
    assert online_endpoint.url == "https://api.example.test/v1"
    assert online_endpoint.api_key == "online-secret"
    assert online_endpoint.model == "gpt-4.1"

    assert {:ok, offline_endpoint} = AI.get_endpoint(:airplane)
    assert offline_endpoint.url == "http://localhost:11434/v1"
    assert offline_endpoint.api_key in [nil, ""]
    assert offline_endpoint.model == "llama3.3"

    assert {:ok, nil} = AI.get_endpoint(:mistral)
    assert AI.airplane_mode?()
    assert {:ok, "gpt-4.1"} = AI.get_model_preference(:chat)
    assert {:ok, "gpt-4.1-mini"} = AI.get_model_preference(:title)
    assert {:ok, "gpt-4.1-vision"} = AI.get_model_preference(:image_analysis)
    assert {:ok, "llama3.3"} = AI.get_model_preference(:airplane_chat)
    assert {:ok, "llama3.2"} = AI.get_model_preference(:airplane_title)
    assert {:ok, "llava:latest"} = AI.get_model_preference(:airplane_image_analysis)

    assert %{supports_tool_calls: true} = BDS.AI.Catalog.model_capabilities("gpt-4.1")
    assert %{supports_tool_calls: true} = BDS.AI.Catalog.model_capabilities("llama3.3")
  end

  test "ai settings refresh models from the configured endpoints" do
    Application.put_env(:bds, :ai_http_client, FakeEndpointModelHttpClient)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      view
      |> element("[data-testid='activity-button'][data-view='settings']")
      |> render_click()

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='settings-project']")
      |> render_click()

    assert html =~ "Refresh Online Models"
    assert html =~ "Refresh Offline Models"

    _html =
      render_change(view, "change_settings_ai", %{
        "settings_ai" => %{
          "online_url" => "https://api.example.test/v1",
          "offline_url" => "http://localhost:11434/v1"
        }
      })

    html =
      view
      |> element("button[phx-click='refresh_settings_ai_models'][phx-value-endpoint='online']")
      |> render_click()

    assert html =~ ~s(<option value="gpt-4.1"></option>)
    assert html =~ ~s(<option value="gpt-4.1-mini"></option>)

    html =
      view
      |> element("button[phx-click='refresh_settings_ai_models'][phx-value-endpoint='airplane']")
      |> render_click()

    assert html =~ ~s(<option value="llama3.3"></option>)
    assert html =~ ~s(<option value="llava:latest"></option>)
  end

  test "status bar airplane toggle persists the active ai mode" do
    assert :ok = AI.set_airplane_mode(false)

    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    refute html =~ ~s(status-bar-item offline-badge active)
    refute AI.airplane_mode?()

    html =
      view
      |> element("[data-testid='status-offline-button']")
      |> render_click()

    assert html =~ ~s(status-bar-item offline-badge active)
    assert AI.airplane_mode?()

    html =
      view
      |> element("[data-testid='status-offline-button']")
      |> render_click()

    refute html =~ ~s(status-bar-item offline-badge active)
    refute AI.airplane_mode?()
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

    html =
      render_hook(view, "sync_layout", %{"sidebar_width" => 420, "assistant_sidebar_width" => 480})

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

    assert {:ok, _tag} =
             Tags.create_tag(%{project_id: project.id, name: "tech", color: "#112233"})

    {:ok, view, html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert html =~ ~s(data-testid="sidebar-search-form")
    assert html =~ ~s(data-testid="sidebar-filter-toggle")
    assert html =~ ~s(class="sidebar-section-header")
    assert html =~ ~s(class="sidebar-actions")
    assert html =~ ~s(data-testid="sidebar-load-more")

    assert html_position(html, ~s(data-testid="sidebar-load-more")) >
             html_position(html, ">Archived<")

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

  test "project switcher, ui language, dashboard recents, and output log are wired", %{
    temp_dir: temp_dir
  } do
    {:ok, other_project} =
      Projects.create_project(%{name: "Second Blog", data_path: Path.join(temp_dir, "second")})

    {:ok, recent_post} =
      Posts.create_post(%{
        project_id: other_project.id,
        title: "Recent Shell Post",
        content: "body"
      })

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

  test "task button opens tasks and post panels render real link and git data", %{
    project: project,
    temp_dir: temp_dir
  } do
    {:ok, target} =
      Posts.create_post(%{project_id: project.id, title: "Target Post", content: "target body"})

    {:ok, target} = Posts.publish_post(target.id)
    target_href = canonical_post_href(target)

    {:ok, source} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Linking Source",
        content: "See [Target](#{target_href})"
      })

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

    assert html =~
             ~s(<button class="panel-tab active" type="button" phx-click="select_panel_tab" phx-value-tab="tasks">)

    assert html =~ ~s(class="task-list") or html =~ "No background tasks running"
  end

  test "metadata diff tasks localize task text, show progress, and open the diff result in the UI" do
    parent = self()
    :ok = BDS.Tasks.clear_finished()

    {:ok, task} =
      BDS.Tasks.submit_task(
        "Metadata Diff",
        fn report ->
          send(parent, {:metadata_diff_worker, self()})
          report.(0.35, "Comparing database and filesystem metadata")

          receive do
            :finish ->
              %{
                kind: "open_editor",
                action: "metadata_diff",
                project_id: "test-project",
                route: "metadata_diff",
                title: "Metadata Diff",
                subtitle: "Database state compared against filesystem metadata",
                editorMeta: [
                  %{label: "Diffs", value: "1"},
                  %{label: "Orphans", value: "1"}
                ],
                payload: %{
                  summary: %{diff_count: 3, orphan_count: 2},
                  diff_reports: [
                    %{
                      entity_type: "post",
                      entity_id: "post-1",
                      label: "Hello DB",
                      meta_label: "2026-04-05T12:00:00Z",
                      differences: [
                        %{field: "slug", db_value: "hello-db", file_value: "hello-file"},
                        %{field: "title", db_value: "Hello DB", file_value: "Hello File"}
                      ]
                    },
                    %{
                      entity_type: "post_translation",
                      entity_id: "post-1-de",
                      differences: [
                        %{field: "excerpt", db_value: "Kurz DB", file_value: "Kurz Datei"}
                      ]
                    },
                    %{
                      entity_type: "media",
                      entity_id: "media-1",
                      differences: [
                        %{field: "alt", db_value: "Alt DB", file_value: "Alt Datei"}
                      ]
                    }
                  ],
                  orphan_reports: [
                    %{path: "posts/2026/04/orphan.md", entity_type: "post"},
                    %{path: "media/2026/04/orphan.txt.meta", entity_type: "media"}
                  ]
                }
              }
          end
        end,
        %{group_name: "Maintenance"}
      )

    assert_receive {:metadata_diff_worker, worker_pid}

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_change(view, "change_ui_language", %{"ui_language" => "de"})

    send(view.pid, :refresh_task_status)

    html =
      view
      |> element("[data-testid='status-task-button']")
      |> render_click()

    assert html =~ "Metadaten-Diff"
    assert html =~ "Vergleicht Datenbank- und Dateisystem-Metadaten"
    assert html =~ "35%"
    assert html =~ ~s(task-status-running)

    worker_ref = Process.monitor(worker_pid)
    send(worker_pid, :finish)
    assert_receive {:DOWN, ^worker_ref, :process, _, _}, 1_000
    completed_task!(task.id)
    send(view.pid, :refresh_task_status)

    html = render(view)

    assert html =~ ~s(data-tab-type="metadata_diff")
    assert html =~ "Metadaten-Diff"
    assert html =~ ~s(data-testid="metadata-diff-tab")
    assert html =~ ~s(data-entity-tab="posts")
    assert html =~ ~s(data-entity-tab="media")
    assert html =~ ~s(data-testid="metadata-diff-field-pill")
    assert html =~ "slug"
    assert html =~ "title"
    assert html =~ "2026-04-05T12:00:00Z"
    assert html =~ "hello-db"
    assert html =~ "hello-file"
    assert html =~ "posts/2026/04/orphan.md"
    refute html =~ "Beitrag · post-1"

    html =
      view
      |> element("[data-testid='metadata-diff-tab'][data-entity-tab='media']")
      |> render_click()

    assert html =~ "Alt DB"
    assert html =~ "Alt Datei"
    refute html =~ "hello-db"
    refute html =~ "posts/2026/04/orphan.md"
    assert html =~ "media/2026/04/orphan.txt.meta"

    _html =
      view
      |> element("[data-testid='metadata-diff-tab'][data-entity-tab='posts']")
      |> render_click()

    html =
      view
      |> element("[data-testid='metadata-diff-field-pill'][data-field='slug']")
      |> render_click()

    assert html =~ "hello-db"
    assert html =~ "hello-file"
    refute html =~ "Kurz DB"
    refute html =~ "posts/2026/04/orphan.md"
  end

  test "metadata diff repair actions queue a repair task and refresh the diff result", %{
    project: project,
    temp_dir: temp_dir
  } do
    :ok = BDS.Tasks.clear_finished()

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Database Post",
               content: "Body",
               excerpt: "Summary",
               language: "en"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    post_path = Path.join(temp_dir, published_post.file_path)

    File.write!(
      post_path,
      [
        "---",
        "id: #{published_post.id}",
        "title: Filesystem Post",
        "slug: #{published_post.slug}",
        "excerpt: Summary",
        "status: published",
        "language: en",
        "createdAt: #{published_post.created_at}",
        "updatedAt: #{published_post.updated_at + 1}",
        "publishedAt: #{published_post.published_at}",
        "tags:",
        "categories:",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert {:ok, queued} = BDS.Desktop.ShellCommands.execute("metadata_diff")
    completed_task!(queued.task_id)
    send(view.pid, :refresh_task_status)

    html = render(view)
    assert html =~ ~s(data-testid="metadata-diff-repair-button")
    assert html =~ ~s(data-field="title")

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    html =
      view
      |> element(
        "[data-testid='metadata-diff-repair-button'][data-direction='file_to_db'][data-field='title']"
      )
      |> render_click()

    assert html =~ "Repair Metadata Diff"

    repair_task = new_task!(existing_ids, "Repair Metadata Diff")
    completed_task!(repair_task.id)
    send(view.pid, :refresh_task_status)
    _html = render(view)

    assert Repo.get!(Post, published_post.id).title == "Filesystem Post"

    assert {:ok, diff} = BDS.Maintenance.metadata_diff(project.id)
    refute Enum.any?(diff.diff_reports, &(&1.entity_id == published_post.id))
  end

  test "metadata diff refresh reruns the diff and replaces the current result", %{
    project: project,
    temp_dir: temp_dir
  } do
    :ok = BDS.Tasks.clear_finished()

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Database Post",
               content: "Body",
               excerpt: "Summary",
               language: "en"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    post_path = Path.join(temp_dir, published_post.file_path)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert {:ok, queued} = BDS.Desktop.ShellCommands.execute("metadata_diff")
    completed_task!(queued.task_id)
    send(view.pid, :refresh_task_status)

    html = render(view)
    refute html =~ "Filesystem Post"

    File.write!(
      post_path,
      [
        "---",
        "id: #{published_post.id}",
        "title: Filesystem Post",
        "slug: #{published_post.slug}",
        "excerpt: Summary",
        "status: published",
        "language: en",
        "createdAt: #{published_post.created_at}",
        "updatedAt: #{published_post.updated_at + 1}",
        "publishedAt: #{published_post.published_at}",
        "tags:",
        "categories:",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    html =
      view
      |> element("button[phx-click='rerun_misc_editor']")
      |> render_click()

    assert html =~ "Metadata Diff"

    refresh_task = new_task!(existing_ids, "Metadata Diff")
    completed_task!(refresh_task.id)
    send(view.pid, :refresh_task_status)

    html = render(view)
    assert html =~ "Filesystem Post"
  end

  test "metadata diff orphan import action queues an import task and removes the orphan", %{
    project: project,
    temp_dir: temp_dir
  } do
    :ok = BDS.Tasks.clear_finished()

    orphan_relative_path = Path.join(["posts", "2026", "04", "orphan-post.md"])
    orphan_full_path = Path.join(temp_dir, orphan_relative_path)
    File.mkdir_p!(Path.dirname(orphan_full_path))

    File.write!(
      orphan_full_path,
      [
        "---",
        "id: orphan-post",
        "title: Orphan Post",
        "slug: orphan-post",
        "status: published",
        "createdAt: 1",
        "updatedAt: 1",
        "publishedAt: 1",
        "tags:",
        "categories:",
        "---",
        "Orphan body",
        ""
      ]
      |> Enum.join("\n")
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert {:ok, queued} = BDS.Desktop.ShellCommands.execute("metadata_diff")
    completed_task!(queued.task_id)
    send(view.pid, :refresh_task_status)

    html = render(view)
    assert html =~ ~s(data-testid="metadata-diff-import-button")
    assert html =~ orphan_relative_path

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    html =
      view
      |> element("[data-testid='metadata-diff-import-button']")
      |> render_click()

    assert html =~ "Import Metadata Diff Orphans"

    import_task = new_task!(existing_ids, "Import Metadata Diff Orphans")
    completed_task!(import_task.id)
    send(view.pid, :refresh_task_status)
    _html = render(view)

    assert Repo.get_by(Post, project_id: project.id, file_path: orphan_relative_path)

    assert {:ok, diff} = BDS.Maintenance.metadata_diff(project.id)
    refute orphan_relative_path in Enum.map(diff.orphan_reports, & &1.file_path)
  end

  test "metadata diff embeddings tab exposes repair actions and clears embedding drift", %{
    project: project
  } do
    :ok = BDS.Tasks.clear_finished()

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Embedding Drift",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    Repo.delete_all(BDS.Embeddings.Key)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert {:ok, queued} = BDS.Desktop.ShellCommands.execute("metadata_diff")
    completed_task!(queued.task_id)
    send(view.pid, :refresh_task_status)

    html =
      view
      |> element("[data-testid='metadata-diff-tab'][data-entity-tab='embeddings']")
      |> render_click()

    assert html =~ "content_hash"
    assert html =~ ~s(data-testid="metadata-diff-repair-button")

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    html =
      view
      |> element(
        "[data-testid='metadata-diff-repair-button'][data-direction='file_to_db'][data-field='content_hash']"
      )
      |> render_click()

    assert html =~ "Repair Metadata Diff"

    repair_task = new_task!(existing_ids, "Repair Metadata Diff")
    completed_task!(repair_task.id)
    send(view.pid, :refresh_task_status)
    _html = render(view)

    assert Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: published_post.id) !=
             nil

    assert {:ok, diff} = BDS.Maintenance.metadata_diff(project.id)

    refute Enum.any?(
             diff.diff_reports,
             &(&1.entity_type == "embedding" and &1.entity_id == published_post.id)
           )
  end

  test "post tabs render a real editor and drive save publish discard flows", %{project: project} do
    assert {:ok, _tag} =
             Tags.create_tag(%{project_id: project.id, name: "alpha", color: "#112233"})

    assert {:ok, _tag} =
             Tags.create_tag(%{project_id: project.id, name: "beta", color: "#445566"})

    assert {:ok, _metadata} = Metadata.add_category(project.id, "notes")
    assert {:ok, _metadata} = Metadata.add_category(project.id, "guides")

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Draft Shell Post",
        content: "Initial body",
        excerpt: "Initial excerpt",
        tags: ["alpha", "beta"],
        categories: ["notes", "guides"]
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-testid="post-editor")
    assert html =~ ~s(data-testid="post-editor-form")
    assert html =~ ~s(name="post_editor[title]")
    assert html =~ ~s(name="post_editor[content]")
    assert html =~ ~s(name="post_editor[excerpt]")
    assert html =~ ~s(data-testid="post-publish-button")
    assert html =~ ~s(data-testid="post-discard-button")
    assert html =~ ~s(data-testid="post-detect-language-button")
    assert html =~ "quick-actions-wrapper"
    assert html =~ "quick-actions-btn"
    assert html =~ "editor-header"
    assert html =~ "editor-content"
    assert html =~ "metadata-toggle-header"
    assert html =~ "editor-translations-flags"
    assert html =~ "editor-header-row"
    assert html =~ "editor-media-panel"
    assert html =~ "editor-body"
    assert html =~ "editor-toolbar"
    assert html =~ "editor-footer"
    assert html =~ "tag-input-container"
    assert html =~ "tag-chip"
    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "notes"
    assert html =~ "guides"
    refute html =~ ~s(phx-click="save_post_editor")
    refute html =~ ~s(data-testid="post-delete-button")
    refute html =~ "gallery-button"
    refute html =~ "Desktop workbench content routed through the Elixir shell."

    html = render_click(view, "toggle_post_editor_quick_actions", %{"id" => post.id})

    assert html =~ "quick-actions-menu"
    assert html =~ "quick-action-item"
    assert html =~ "quick-actions-divider"

    html = render_click(view, "set_post_editor_mode", %{"id" => post.id, "mode" => "preview"})

    assert html =~ ~s(data-testid="post-editor-preview")
    assert html =~ "editor-preview-frame"
    refute html =~ ~s(data-testid="post-editor-content")

    html = render_click(view, "set_post_editor_mode", %{"id" => post.id, "mode" => "markdown"})

    assert html =~ ~s(data-testid="post-editor-content")
    assert html =~ ~s(data-monaco-language="markdown-with-macros")
    assert html =~ ~s(phx-hook="MonacoEditor")
    refute html =~ "post-editor-markdown-highlight"

    html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Updated Shell Post",
          content: "Updated body",
          excerpt: "Updated excerpt",
          tags: "alpha, beta",
          categories: "notes, guides",
          author: "Ada Lovelace",
          language: "de",
          do_not_translate: "false"
        }
      })
      |> render_change()

    assert html =~ ~s(class="tab active dirty")
    assert html =~ "Updated Shell Post"

    _html = render_click(view, "save_post_editor", %{"id" => post.id})

    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Updated Shell Post"
    assert saved_post.content == "Updated body"
    assert saved_post.excerpt == "Updated excerpt"
    assert saved_post.tags == ["alpha", "beta"]
    assert saved_post.categories == ["notes", "guides"]
    assert saved_post.author == "Ada Lovelace"
    assert saved_post.language == "de"

    html = render_click(view, "publish_post_editor", %{"id" => post.id})

    assert html =~ ~s(data-testid="post-status-badge")
    assert html =~ ~s(data-testid="post-delete-button")
    refute html =~ ~s(data-testid="post-publish-button")
    refute html =~ ~s(data-testid="post-discard-button")
    assert Posts.get_post!(post.id).status == :published

    _html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Published Shell Post",
          content: "Draft changes after publish",
          excerpt: "Changed after publish",
          tags: "alpha, beta",
          categories: "notes, guides",
          author: "Ada Lovelace",
          language: "de",
          do_not_translate: "false"
        }
      })
      |> render_change()

    _html = render_click(view, "save_post_editor", %{"id" => post.id})
    assert Posts.get_post!(post.id).status == :draft

    html = render_click(view, "discard_post_editor", %{"id" => post.id})

    discarded_post = Posts.get_post!(post.id)
    assert html =~ "Updated Shell Post"
    assert discarded_post.status == :published
    assert discarded_post.content == nil
    assert discarded_post.title == "Updated Shell Post"
  end

  defp completed_task!(task_id, attempts \\ 50)

  defp completed_task!(_task_id, 0), do: flunk("task did not complete in time")

  defp completed_task!(task_id, attempts) do
    case Enum.find(BDS.Tasks.list_tasks(), &(&1.id == task_id and &1.status == :completed)) do
      nil ->
        Process.sleep(20)
        completed_task!(task_id, attempts - 1)

      task ->
        task
    end
  end

  defp new_task!(existing_ids, name, attempts \\ 50)

  defp new_task!(_existing_ids, _name, 0), do: flunk("new task was not created in time")

  defp new_task!(existing_ids, name, attempts) do
    case Enum.find(
           BDS.Tasks.list_tasks(),
           &(&1.name == name and not MapSet.member?(existing_ids, &1.id))
         ) do
      nil ->
        Process.sleep(20)
        new_task!(existing_ids, name, attempts - 1)

      task ->
        task
    end
  end

  test "published post editor loads body from file and renders markdown-only editor", %{
    project: project
  } do
    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Published Editor Post",
        content: "# Heading\n\n```elixir\nIO.puts(:ok)\n```\n",
        excerpt: "Published excerpt"
      })

    assert {:ok, _published} = Posts.publish_post(post.id)
    published = Posts.get_post!(post.id)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => published.id,
        "title" => published.title,
        "subtitle" => "published"
      })

    assert html =~ ~s(data-testid="post-editor-content")

    assert Regex.match?(
             ~r/name="post_editor\[content\]"[^>]*># Heading\s+```elixir\s+IO\.puts\(:ok\)\s+```/s,
             html
           )

    assert html =~ ~s(data-monaco-language="markdown-with-macros")
    assert html =~ ~s(phx-hook="MonacoEditor")
    refute html =~ "post-editor-markdown-highlight"
    refute html =~ ~s(phx-value-mode="visual")
  end

  test "media tabs render a real editor and drive explicit save flows", %{
    project: project,
    temp_dir: temp_dir
  } do
    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Linked Shell Post",
        content: "Body"
      })

    source_path = Path.join(temp_dir, "cover.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Manual Cover",
               alt: "Cover alt",
               caption: "Cover caption",
               author: "Initial Author",
               language: "en",
               tags: ["cover", "hero"]
             })

    assert {:ok, _translation} =
             Media.upsert_media_translation(media.id, "de", %{
               title: "Titelbild",
               alt: "Alt DE",
               caption: "Beschriftung DE"
             })

    assert {:ok, _result} =
             Repo.query(
               "INSERT INTO post_media (id, project_id, post_id, media_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)",
               [Ecto.UUID.generate(), project.id, post.id, media.id, 0, Persistence.now_ms()]
             )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => media.original_name
      })

    assert html =~ ~s(data-testid="media-editor")
    assert html =~ ~s(data-testid="media-editor-form")
    assert html =~ ~s(name="media_editor[title]")
    assert html =~ ~s(name="media_editor[alt]")
    assert html =~ ~s(name="media_editor[caption]")
    assert html =~ ~s(name="media_editor[tags]")
    assert html =~ ~s(data-testid="media-save-button")
    assert html =~ ~s(data-testid="media-delete-button")
    assert html =~ "quick-actions-wrapper"
    assert html =~ "media-translations-section"
    assert html =~ "linked-posts-section"
    assert html =~ "Manual Cover"
    assert html =~ "Linked Shell Post"
    assert html =~ "Titelbild"
    refute html =~ "Desktop workbench content routed through the Elixir shell."

    html = render_click(view, "toggle_media_editor_quick_actions", %{"id" => media.id})

    assert html =~ "quick-actions-menu"
    assert html =~ "Detect Language"
    assert html =~ "Translate"

    html =
      view
      |> form("[data-testid='media-editor-form']", %{
        media_editor: %{
          title: "Updated Cover",
          alt: "Updated alt",
          caption: "Updated caption",
          tags: "cover, feature",
          author: "Ada Lovelace",
          language: "fr"
        }
      })
      |> render_change()

    assert html =~ "Updated Cover"

    _html = render_click(view, "save_media_editor", %{"id" => media.id})

    saved_media = Repo.get!(BDS.Media.Media, media.id)
    assert saved_media.title == "Updated Cover"
    assert saved_media.alt == "Updated alt"
    assert saved_media.caption == "Updated caption"
    assert saved_media.tags == ["cover", "feature"]
    assert saved_media.author == "Ada Lovelace"
    assert saved_media.language == "fr"
  end

  test "media editor follows the old-app translation editing flow", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "hero.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Legacy Cover",
               alt: "Legacy alt",
               caption: "Legacy caption",
               language: "en"
             })

    assert {:ok, _translation} =
             Media.upsert_media_translation(media.id, "de", %{
               title: "Titelbild",
               alt: "Alt DE",
               caption: "Beschriftung DE"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => media.original_name
      })

    assert html =~ ~s(class="editor-content media-editor")
    assert html =~ ~s(class="quick-actions-wrapper")
    refute html =~ ~s(class="media-editor-form")

    assert has_element?(
             view,
             "[data-testid='media-editor'] .editor-content.media-editor .media-details"
           )

    assert has_element?(
             view,
             "[data-testid='media-editor'] .editor-content.media-editor .media-details .media-translations-section"
           )

    assert has_element?(
             view,
             "[data-testid='media-editor'] .editor-content.media-editor .media-details .linked-posts-section"
           )

    html = render_click(view, "edit_media_translation", %{"id" => media.id, "language" => "de"})

    assert html =~ ~s(class="translation-modal-backdrop")
    assert html =~ ~s(class="translation-modal")
    assert html =~ ~s(name="media_translation[title]")
    assert html =~ ~s(name="media_translation[alt]")
    assert html =~ ~s(name="media_translation[caption]")
  end

  test "settings and media editors render localized labels when the UI language changes", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "localized-hero.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Lokales Bild",
               alt: "Alt",
               caption: "Beschriftung",
               language: "de"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> form("[data-testid='status-language-form']", %{ui_language: "de"})
      |> render_change()

    assert html =~ "Beiträge durchsuchen..."

    settings_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "settings",
        "id" => "settings-editor",
        "title" => "Editor",
        "subtitle" => "Editor settings"
      })

    assert settings_html =~ "Standard-Bearbeitungsmodus"
    refute settings_html =~ "Default Editor Mode"

    media_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => media.original_name
      })

    assert media_html =~ "Dateiname"
    assert media_html =~ "Verknüpfte Beiträge"
    refute media_html =~ "File Name"
    refute media_html =~ "Linked Posts"
  end

  test "remaining step-5 routes render dedicated editors instead of the generic shell placeholder",
       %{project: project} do
    assert {:ok, script} =
             Scripts.create_script(%{
               project_id: project.id,
               title: "Sync Script",
               kind: :utility,
               content: "def main():\n    return 'ok'\n"
             })

    assert {:ok, template} =
             Templates.create_template(%{
               project_id: project.id,
               title: "Post Template",
               kind: :post,
               content: "<article>{{ post.title }}</article>"
             })

    assert {:ok, _tag} = Tags.create_tag(%{project_id: project.id, name: "feature"})
    assert {:ok, conversation} = AI.start_chat(%{title: "Editor Chat"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    settings_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "settings",
        "id" => "settings",
        "title" => "Settings",
        "subtitle" => "Project settings"
      })

    assert settings_html =~ ~s(class="settings-view-shell")
    assert settings_html =~ ~s(class="setting-section")
    refute settings_html =~ "Desktop workbench content routed through the Elixir shell."

    tags_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "tags",
        "id" => "tags",
        "title" => "Tags",
        "subtitle" => "Manage tags"
      })

    assert tags_html =~ ~s(class="tags-view-shell")
    assert tags_html =~ ~s(class="tags-section")
    refute tags_html =~ "Desktop workbench content routed through the Elixir shell."

    style_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "style",
        "id" => "style",
        "title" => "Style",
        "subtitle" => "Theme preview"
      })

    assert style_html =~ ~s(class="style-view")
    assert style_html =~ ~s(class="style-theme-picker")
    refute style_html =~ "Desktop workbench content routed through the Elixir shell."

    script_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "scripts",
        "id" => script.id,
        "title" => script.title,
        "subtitle" => script.slug
      })

    assert script_html =~ ~s(class="scripts-view-shell")
    assert script_html =~ "scripts-monaco"
    assert script_html =~ ~s(data-monaco-language="lua")
    assert script_html =~ ~s(data-monaco-word-wrap="on")
    assert script_html =~ ~s(phx-hook="MonacoEditor")
    refute script_html =~ "Desktop workbench content routed through the Elixir shell."

    template_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "templates",
        "id" => template.id,
        "title" => template.title,
        "subtitle" => template.slug
      })

    assert template_html =~ ~s(class="templates-view-shell")
    assert template_html =~ "templates-monaco"
    assert template_html =~ ~s(data-monaco-language="liquid")
    assert template_html =~ ~s(data-monaco-word-wrap="on")
    assert template_html =~ ~s(phx-hook="MonacoEditor")
    refute template_html =~ "Desktop workbench content routed through the Elixir shell."

    chat_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert chat_html =~ ~s(class="chat-panel")
    assert chat_html =~ ~s(class="chat-input-container")
    refute chat_html =~ "Desktop workbench content routed through the Elixir shell."
  end

  test "chat editor uses the model name itself as the selector" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Selector Chat", model: "qwen3.5-122b"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ ~s(data-testid="chat-model-selector-button")
    assert html =~ ~s(class="chat-panel-title-main")
    assert html =~ ~s(class="chat-model-selector-wrap")
    assert html =~ ~s(class="chat-model-selector-button chat-model-selector-inline")
    refute html =~ ~s(class="chat-panel-header-actions")

    css = File.read!(Path.expand("../../../priv/ui/app.css", __DIR__))
    assert css =~ ".chat-model-selector-wrap"
    assert css =~ "left: 0;"
    assert css =~ "right: auto;"

    refute css =~
             ".chat-model-selector-menu {\n  position: absolute;\n  top: calc(100% + 4px);\n  right: 16px;"

    assert css =~ ".chat-panel .chat-model-selector-button.chat-model-selector-inline"
    assert css =~ ".chat-panel .chat-model-selector-caret"
    assert css =~ "position: static;"
  end

  test "chat editor renders legacy model controls, collapsed tool pills, and dismissible A2UI surfaces" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Editor Chat", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "Show me a table",
        created_at: now
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Here is the current summary.",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-table",
              "name" => "render_table",
              "arguments" => %{"title" => "Blog Stats", "columns" => ["Metric", "Value"]}
            }
          ]),
        created_at: now + 1
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :tool,
        tool_call_id: "call-table",
        content:
          Jason.encode!(%{
            "type" => "table",
            "title" => "Blog Stats",
            "columns" => ["Metric", "Value"],
            "rows" => [["Posts", "1"], ["Media", "0"]]
          }),
        created_at: now + 2
      })
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ ~s(data-testid="chat-model-selector-button")
    assert html =~ "gpt-4.1"
    assert html =~ ~s(data-testid="chat-tool-marker")
    assert html =~ ~s(data-testid="chat-tool-marker-details")
    assert html =~ "render_table"
    refute html =~ ~s(data-testid="chat-tool-surface")
    assert html =~ ~s(data-testid="chat-inline-surface")
    assert html =~ ~s(data-testid="chat-inline-surface-dismiss")
    assert html =~ "Blog Stats"
    assert html =~ "Metric"
    assert html =~ "Posts"

    dismissed_html =
      render_click(view, "dismiss_chat_surface", %{
        "surface-id" => Regex.run(~r/id="([^"]+-surface-0)"/, html) |> Enum.at(1)
      })

    refute dismissed_html =~ ~s(data-testid="chat-inline-surface")
  end

  test "chat editor folds tool-only assistant steps into the final assistant answer" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Tool Chat", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "Show posts per month",
        created_at: now
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: nil,
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-count-posts",
              "name" => "count_posts",
              "arguments" => %{"groupBy" => ["month"], "year" => 2026}
            }
          ]),
        created_at: now + 1
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :tool,
        tool_call_id: "call-count-posts",
        content: Jason.encode!([%{"month" => 5, "count" => 3}]),
        created_at: now + 2
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Here is the chart.",
        created_at: now + 3
      })
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ "count_posts"
    assert html =~ "Here is the chart."
    assert html =~ ~s(<span class="chat-message-role">Assistant</span>)

    assert length(:binary.matches(html, ~s(<span class="chat-message-role">Assistant</span>))) == 1
  end

  test "chat editor marks user message text as compact" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Compact Chat", model: "gpt-4.1"})

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "wie viele Posts sind im Blog?",
        created_at: Persistence.now_ms()
      })
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ ~s(data-testid="chat-user-message-text")
    assert html =~ ~s(class="chat-message-text chat-user-message-text")

    assert html =~
             ~s(<div class="chat-message-text chat-user-message-text" data-testid="chat-user-message-text">wie viele Posts sind im Blog?</div>)

    css = File.read!(Path.expand("../../../priv/ui/app.css", __DIR__))
    assert css =~ ".chat-panel .chat-message.user .chat-message-content"
    assert css =~ "background: transparent;"
    assert css =~ "border: 0;"
    assert css =~ "padding: 6px 12px;"
    assert css =~ "line-height: 1.35;"
  end

  test "chat editor keeps empty input single-line until content grows" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Input Sizing", model: "gpt-4.1"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ ~s(rows="1")
    assert html =~ ~s(class="chat-input chat-surface-input")

    css = File.read!(Path.expand("../../../priv/ui/app.css", __DIR__))
    assert css =~ "--chat-input-line-height: 20px;"
    assert css =~ "--chat-input-min-height: 20px;"
    assert css =~ ".chat-panel .chat-input-container"
    assert css =~ "padding: 8px 16px;"
    assert css =~ "padding: 6px 8px;"
    assert css =~ ".chat-panel .chat-input-wrapper"
    assert css =~ "min-height: 30px;"
    assert css =~ "padding: 4px 6px;"
    assert css =~ ".chat-panel .chat-input"
    assert css =~ "box-sizing: border-box;"
    assert css =~ "margin: 0;"
    assert css =~ "height: var(--chat-input-min-height);"
    assert css =~ "min-height: var(--chat-input-min-height);"
    assert css =~ "overflow-y: hidden;"
    assert css =~ ".chat-panel .chat-send-button"
    assert css =~ "width: 22px;"
    assert css =~ "height: 22px;"
    assert css =~ "max-width: 22px;"
    assert css =~ "max-height: 22px;"
    assert css =~ "padding: 0;"

    live_js = File.read!(Path.expand("../../../priv/ui/live.js", __DIR__))

    assert live_js =~
             "minHeight = parseFloat(styles.getPropertyValue(\"--chat-input-min-height\"))"

    assert live_js =~ "textarea.value.trim() === \"\""
    assert live_js =~ "textarea.rows = 1;"
    assert live_js =~ "textarea.style.minHeight = `${minHeight}px`;"
    assert live_js =~ "textarea.style.height = `${minHeight}px`;"
    assert live_js =~ "textarea.style.maxHeight = `${minHeight}px`;"
    assert live_js =~ "textarea.style.height = \"0px\";"
    assert live_js =~ "textarea.style.overflowY = nextHeight >= maxHeight ? \"auto\" : \"hidden\""
  end

  test "chat editor groups selector models by provider and uses catalog labels" do
    updated_at = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.CatalogProvider.changeset(%BDS.AI.CatalogProvider{}, %{
        id: "openai",
        name: "OpenAI",
        updated_at: updated_at
      })
    )

    Repo.insert!(
      BDS.AI.CatalogProvider.changeset(%BDS.AI.CatalogProvider{}, %{
        id: "ollama",
        name: "Ollama",
        updated_at: updated_at
      })
    )

    Repo.insert!(
      BDS.AI.Model.changeset(%BDS.AI.Model{}, %{
        provider: "openai",
        model_id: "gpt-4o",
        name: "GPT-4o",
        context_window: 128_000,
        max_input_tokens: 128_000,
        max_output_tokens: 16_384,
        updated_at: updated_at
      })
    )

    Repo.insert!(
      BDS.AI.Model.changeset(%BDS.AI.Model{}, %{
        provider: "ollama",
        model_id: "llama3.3",
        name: "Llama 3.3",
        context_window: 128_000,
        max_input_tokens: 128_000,
        max_output_tokens: 8_192,
        updated_at: updated_at
      })
    )

    assert {:ok, _endpoint} =
             AI.put_endpoint(:airplane, %{
               url: "http://localhost:11434/v1",
               api_key: nil,
               model: "llama3.3"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Grouped Models", model: "gpt-4o"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    html =
      view
      |> element("[data-testid='chat-model-selector-button']")
      |> render_click()

    assert html =~ ~s(data-testid="chat-model-provider-group")
    assert html =~ ~s(data-provider="openai")
    assert html =~ ~s(data-provider="ollama")
    assert html =~ ">OpenAI<"
    assert html =~ ">Ollama<"
    assert html =~ ">GPT-4o<"
    assert html =~ ">Llama 3.3<"
  end

  test "chat editor renders API-key-required state when online chat is not configured" do
    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: nil,
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Needs Setup", model: "gpt-4.1"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ "AI Chat Setup"
    assert html =~ "API Key Required"
    assert html =~ "Open Settings"
    refute html =~ ~s(data-testid="chat-input-container")
  end

  test "chat editor renders assistant markdown and dispatches assistant navigation actions", %{
    project: project
  } do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Action Post",
               content: "Body",
               language: "en"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Action Chat", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "Open the post",
        created_at: now
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Use **markdown** to jump to the editor.",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-card",
              "name" => "render_card",
              "arguments" => %{
                "title" => "Quick Action",
                "body" => "Open the related post editor.",
                "actions" => [
                  %{
                    "label" => "Open Post",
                    "action" => "openPost",
                    "payload" => %{"postId" => post.id}
                  }
                ]
              }
            }
          ]),
        created_at: now + 1
      })
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ "<strong>markdown</strong>"
    assert html =~ ~s(data-testid="chat-inline-surface")
    assert html =~ "Quick Action"
    assert html =~ "Open Post"

    html =
      view
      |> element("[data-testid='chat-surface-action'][data-action='openPost']")
      |> render_click()

    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="#{post.id}")
  end

  test "chat editor shows in-flight stop state and can abort a running turn" do
    assert :ok = AI.set_airplane_mode(false)

    server =
      start_supervised!({Bandit, plug: DelayedChatServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "online-secret",
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Slow Chat", model: "gpt-4.1"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    _html = render_change(view, "change_chat_editor_input", %{"message" => "Please wait"})

    html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    assert html =~ ~s(data-testid="chat-abort-button")
    assert html =~ ~s(data-testid="chat-streaming-thinking")

    html =
      view
      |> element("[data-testid='chat-abort-button']")
      |> render_click()

    refute html =~ ~s(data-testid="chat-abort-button")

    Process.sleep(350)
    refute render(view) =~ "Delayed response"
  end

  test "chat editor keeps the in-flight user turn visible and disables input while streaming" do
    assert :ok = AI.set_airplane_mode(false)

    server =
      start_supervised!({Bandit, plug: DelayedChatServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "online-secret",
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Pending Chat", model: "gpt-4.1"})

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Earlier answer",
        created_at: Persistence.now_ms()
      })
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    _html = render_change(view, "change_chat_editor_input", %{"message" => "Newest question"})

    html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    {assistant_index, _length} = :binary.match(html, "Earlier answer")
    {user_index, _length} = :binary.match(html, "Newest question")

    assert assistant_index < user_index
    assert html =~ ~r/<textarea[^>]*class="chat-input chat-surface-input"[^>]*disabled/

    send(view.pid, {
      :chat_tool_call,
      conversation.id,
      %{
        id: "call-streaming-chart",
        name: "render_chart",
        arguments: %{
          "title" => "Streaming Chart",
          "chartType" => "bar",
          "series" => [%{"label" => "Posts", "value" => 3}]
        }
      }
    })

    html = render(view)
    assert html =~ ~s(data-testid="chat-streaming-message")
    assert html =~ ~s(data-testid="chat-inline-surface")
    assert html =~ "Streaming Chart"

    html =
      view
      |> element("[data-testid='chat-abort-button']")
      |> render_click()

    refute html =~ ~s(data-testid="chat-abort-button")

    Process.sleep(350)
    refute render(view) =~ "Delayed response"
  end

  test "translation validation route renders dedicated cards and fix controls", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Hello",
               content: "World",
               language: "en"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Hallo",
               content: "Welt",
               status: :published
             })

    invalid_file_path =
      Path.join([
        temp_dir,
        Path.dirname(published_post.file_path),
        "#{published_post.slug}.en.md"
      ])

    File.write!(
      invalid_file_path,
      [
        "---",
        "translationFor: #{post.id}",
        "language: en",
        "title: Wrong Language",
        "---",
        "Invalid translation",
        ""
      ]
      |> Enum.join("\n")
    )

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    assert {:ok, queued} = BDS.Desktop.ShellCommands.execute("validate_translations")
    completed_task!(queued.task_id)
    send(view.pid, :refresh_task_status)

    html = render(view)

    assert html =~ ~s(class="translation-validation-view")
    assert html =~ ~s(data-testid="translation-validation-revalidate")
    assert html =~ ~s(data-testid="translation-validation-fix")
    assert html =~ ~s(data-testid="translation-validation-card")
    assert html =~ invalid_file_path
  end

  test "git diff route renders a structured Monaco diff surface for working tree changes", %{
    temp_dir: temp_dir
  } do
    posts_dir = Path.join(temp_dir, "posts")
    File.mkdir_p!(posts_dir)

    file_path = Path.join(posts_dir, "first.md")
    File.write!(file_path, "Old content\n")

    init_git_repo!(temp_dir, "initial")
    File.write!(file_path, "New content\n")

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "git_diff",
        "id" => "git-working-tree",
        "title" => "Working tree",
        "subtitle" => "Working tree and history"
      })

    assert html =~ ~s(class="git-diff-view")
    assert html =~ ~s(data-testid="git-diff-file-select")
    assert html =~ "posts/first.md"
    assert html =~ ~s(phx-hook="MonacoDiffEditor")
    refute html =~ ~s(<pre><code>)
  end

  test "settings sidebar categories render the full old-app section model and target the requested section" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "settings",
        "id" => "settings-ai",
        "title" => "AI",
        "subtitle" => "Assistant settings"
      })

    assert html =~ ~s(id="settings-section-project")
    assert html =~ ~s(id="settings-section-editor")
    assert html =~ ~s(id="settings-section-content")
    assert html =~ ~s(id="settings-section-ai")
    assert html =~ ~s(id="settings-section-technology")
    assert html =~ ~s(id="settings-section-publishing")
    assert html =~ ~s(id="settings-section-data")
    assert html =~ ~s(id="settings-section-mcp")
    assert html =~ ~s(data-selected-settings-section="ai")
  end

  test "template sidebar exposes old-app style delete control and removes template rows", %{
    project: project
  } do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Sidebar Template",
               kind: :post,
               content: "<article>{{ post.content }}</article>"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='activity-button'][data-view='templates']")
      |> render_click()

    assert html =~ "Sidebar Template"
    assert html =~ ~s(data-testid="sidebar-delete-template")

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='#{template.id}']")
      |> render_click()

    assert html =~ ~s(data-tab-type="templates")
    assert html =~ ~s(data-tab-id="#{template.id}")

    html =
      view
      |> element("[data-testid='sidebar-delete-template'][data-item-id='#{template.id}']")
      |> render_click()

    assert BDS.Repo.get(BDS.Templates.Template, template.id) == nil
    refute html =~ "Sidebar Template"
    refute html =~ ~s(data-tab-type="templates")
    refute html =~ ~s(data-tab-id="#{template.id}")
  end

  defp seed_sidebar_posts(project_id) do
    now = Persistence.now_ms()

    entries =
      [
        sidebar_post(project_id, "alpha-post", "Alpha Post", now + 3_000, ["tech"], ["notes"]),
        sidebar_post(project_id, "beta-post", "Beta Post", now + 2_000, ["design"], ["guides"])
      ] ++
        Enum.map(1..498, fn index ->
          sidebar_post(
            project_id,
            "filler-#{index}",
            "Filler #{index}",
            now - index,
            ["filler"],
            ["archive"]
          )
        end) ++
        [
          sidebar_post(project_id, "overflow-post", "Overflow Post", now - 10_000, ["tech"], [
            "notes"
          ])
        ]

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
