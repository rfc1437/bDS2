defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.Persistence
  alias BDS.AI
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
       %{status: 200, headers: %{}, body: Jason.encode!(%{"data" => [%{"id" => "gpt-4.1"}, %{"id" => "gpt-4.1-mini"}]})}}
    end

    def get("http://localhost:11434/v1/models", _headers) do
      {:ok,
       %{status: 200, headers: %{}, body: Jason.encode!(%{"data" => [%{"id" => "llama3.3"}, %{"id" => "llava:latest"}]})}}
    end

    def get(_url, _headers), do: {:error, :not_found}
  end

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir = Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")
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

  test "sidebar headers expose old-app create actions for posts, media, scripts, templates, and imports" do
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
      |> element("[data-testid='activity-button'][data-view='import']")
      |> render_click()

    assert html =~ ~s(data-sidebar-action="import")
  end

  test "sidebar create actions follow the old-app post, script, template, and import flows", %{project: project} do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
    post_count_before = Repo.aggregate(Post, :count, :id)
    script_count_before = Repo.aggregate(BDS.Scripts.Script, :count, :id)
    template_count_before = Repo.aggregate(BDS.Templates.Template, :count, :id)
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

    _html = render_click(view, "select_view", %{"view" => "import"})

    html =
      view
      |> element("[data-testid='sidebar-create-action'][data-sidebar-action='import']")
      |> render_click()

    assert Repo.aggregate(ImportDefinitions.ImportDefinition, :count, :id) == import_count_before + 1

    created_definition = Repo.one!(ImportDefinitions.ImportDefinition)
    assert created_definition.project_id == project.id
    assert created_definition.name == "New Import Definition"
    assert html =~ ~s(data-tab-type="import")
    assert html =~ ~s(data-tab-id="#{created_definition.id}")
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

  test "shell live renders the legacy git activity badge from remote behind count" do
    Application.put_env(:bds, :git_remote_state_provider, fn _project_id, _opts ->
      {:ok, %{local_branch: "main", upstream_branch: "origin/main", has_upstream: true, ahead: 0, behind: 7}}
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
          "online_title_model" => "gpt-4.1-mini",
          "online_image_analysis_model" => "gpt-4.1-vision",
          "offline_url" => "http://localhost:11434/v1",
          "offline_api_key" => "",
          "offline_chat_model" => "llama3.3",
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

  test "metadata diff tasks localize task text, show progress, and open the diff result in the UI" do
    parent = self()
    :ok = BDS.Tasks.clear_finished()

    {:ok, _task} =
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
                  summary: %{diff_count: 1, orphan_count: 1},
                  diff_reports: [
                    %{
                      entity_type: "post",
                      entity_id: "post-1",
                      differences: [
                        %{field: "slug", db_value: "hello-db", file_value: "hello-file"}
                      ]
                    }
                  ],
                  orphan_reports: [
                    %{path: "posts/2026/04/orphan.md", entity_type: "post"}
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

    send(worker_pid, :finish)
    send(view.pid, :refresh_task_status)

    html = render(view)

    assert html =~ ~s(data-tab-type="metadata_diff")
    assert html =~ "Metadaten-Diff"
    assert html =~ "slug"
    assert html =~ "hello-db"
    assert html =~ "hello-file"
    assert html =~ "posts/2026/04/orphan.md"
  end

  test "post tabs render a real editor and drive save publish discard flows", %{project: project} do
    assert {:ok, _tag} = Tags.create_tag(%{project_id: project.id, name: "alpha", color: "#112233"})
    assert {:ok, _tag} = Tags.create_tag(%{project_id: project.id, name: "beta", color: "#445566"})
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

  test "published post editor loads body from file and renders markdown-only editor", %{project: project} do
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
    assert Regex.match?(~r/name="post_editor\[content\]"[^>]*># Heading\s+```elixir\s+IO\.puts\(:ok\)\s+```/s, html)
    assert html =~ "post-editor-markdown-surface"
    refute html =~ ~s(phx-value-mode="visual")
  end

  test "media tabs render a real editor and drive explicit save flows", %{project: project, temp_dir: temp_dir} do
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

  test "media editor follows the old-app translation editing flow", %{project: project, temp_dir: temp_dir} do
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
    assert has_element?(view, "[data-testid='media-editor'] .editor-content.media-editor .media-details")
    assert has_element?(view, "[data-testid='media-editor'] .editor-content.media-editor .media-details .media-translations-section")
    assert has_element?(view, "[data-testid='media-editor'] .editor-content.media-editor .media-details .linked-posts-section")

    html = render_click(view, "edit_media_translation", %{"id" => media.id, "language" => "de"})

    assert html =~ ~s(class="translation-modal-backdrop")
    assert html =~ ~s(class="translation-modal")
    assert html =~ ~s(name="media_translation[title]")
    assert html =~ ~s(name="media_translation[alt]")
    assert html =~ ~s(name="media_translation[caption]")
  end

  test "settings and media editors render localized labels when the UI language changes", %{project: project, temp_dir: temp_dir} do
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

  test "remaining step-5 routes render dedicated editors instead of the generic shell placeholder", %{project: project} do
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
    assert script_html =~ ~s(class="scripts-monaco")
    refute script_html =~ "Desktop workbench content routed through the Elixir shell."

    template_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "templates",
        "id" => template.id,
        "title" => template.title,
        "subtitle" => template.slug
      })

    assert template_html =~ ~s(class="templates-view-shell")
    assert template_html =~ ~s(class="templates-monaco")
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

  test "template sidebar exposes old-app style delete control and removes template rows", %{project: project} do
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
