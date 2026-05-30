defmodule BDS.Desktop.ShellLiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @shell_live_source_root Path.expand("../../../lib/bds/desktop/shell_live", __DIR__)
  @endpoint BDS.Desktop.Endpoint
  @css_source_files [
    "tokens.css",
    "shell.css",
    "sidebar.css",
    "tabs.css",
    "editor.css",
    "forms.css",
    "panel.css",
    "assistant.css",
    "overlays.css",
    "menu_editor.css",
    "media_editor.css",
    "import_editor.css",
    "utilities.css"
  ]

  defp desktop_css_source do
    @css_source_files
    |> Enum.map(&File.read!(Path.expand("../../../assets/css/#{&1}", __DIR__)))
    |> Enum.join("\n")
  end

  defp phase3_post_editor_assigns do
    %{
      myself: nil,
      post_editor: %{
        id: 42,
        dirty?: true,
        display_title: "Phase 3 Post",
        status: :draft,
        save_state: :saving,
        quick_actions_open?: false,
        can_publish?: true,
        discard_title: "Discard draft",
        discard_label: "Discard",
        can_delete?: true,
        metadata_expanded: true,
        translation_flags: [
          %{language: "en", status: :draft, active: true, label: "English", flag: "EN"}
        ],
        form: %{
          "title" => "Phase 3 Post",
          "author" => "Author",
          "language" => "en",
          "do_not_translate" => false,
          "template_slug" => "",
          "excerpt" => "Excerpt",
          "content" => "# Hello",
          "tags" => "elixir",
          "categories" => "news"
        },
        tag_chips: [%{name: "elixir", color: "#3b82f6"}],
        tag_query: "",
        tag_suggestions: [],
        tag_query_addable?: false,
        languages: ["en", "de"],
        detect_language_enabled?: true,
        slug: "phase-3-post",
        category_values: ["news"],
        category_query: "",
        category_suggestions: [],
        category_query_addable?: false,
        show_template_selector?: true,
        template_options: [%{slug: "default", title: "Default"}],
        post_links: %{backlinks: [], outlinks: []},
        linked_media: [],
        excerpt_expanded: true,
        mode: :markdown,
        gallery_count: 1,
        preview_url: nil,
        footer: %{created_at: "2026-05-04", updated_at: "2026-05-04", published_at: nil},
        can_translate?: true
      }
    }
  end

  defp phase3_media_editor_assigns do
    %{
      myself: nil,
      media_editor: %{
        dirty?: true,
        display_title: "Hero Image",
        save_state: :saved,
        quick_actions_open?: false,
        is_image: true,
        can_detect_language?: true,
        can_translate?: true,
        preview_url: "/media/hero.jpg",
        form: %{
          "title" => "Hero Image",
          "alt" => "Hero alt",
          "caption" => "Caption",
          "tags" => "cover",
          "author" => "Author",
          "language" => "en"
        },
        original_name: "hero.jpg",
        mime_type: "image/jpeg",
        file_size: "42 KB",
        dimensions: "1200x800",
        languages: ["en", "de"],
        translations: [],
        post_picker_open?: false,
        post_picker_query: "",
        post_picker_results: [],
        post_picker_overflow_count: 0,
        linked_posts: [],
        editing_translation: nil
      }
    }
  end

  defp phase3_script_editor_assigns do
    %{
      myself: nil,
      script_editor: %{
        id: 7,
        title: "Build Feed",
        slug: "build-feed",
        kind: "utility",
        entrypoint: "run",
        enabled: true,
        content: "print('ok')",
        entrypoints: ["run"],
        status: :draft,
        can_publish?: true,
        created_at: 1_714_816_000,
        updated_at: 1_714_816_000
      }
    }
  end

  defp phase3_template_editor_assigns do
    %{
      myself: nil,
      template_editor: %{
        id: 9,
        title: "Post Template",
        slug: "post-template",
        kind: :post,
        enabled: true,
        content: "{{ content }}",
        status: :draft,
        can_publish?: true,
        created_at: 1_714_816_000,
        updated_at: 1_714_816_000
      }
    }
  end

  defp phase3_chat_editor_assigns do
    %{
      myself: nil,
      chat_editor: %{
        id: 5,
        needs_api_key?: false,
        title: "AI Assistant",
        effective_model: "gpt-4.1",
        model_selector_open?: false,
        available_models: [],
        available_model_groups: [],
        messages: [],
        is_streaming: false,
        pending_user_message: nil,
        streaming_content: "",
        streaming_tool_markers: [],
        streaming_inline_surfaces: [],
        input: "",
        send_disabled?: true,
        action_error: nil
      }
    }
  end

  defp phase3_menu_editor_assigns do
    %{
      myself: nil,
      menu_editor: %{
        draft: nil,
        title: "Navigation",
        description: "Manage site navigation",
        can_move_up?: false,
        can_move_down?: false,
        can_indent?: false,
        can_unindent?: false,
        can_delete?: false,
        items: []
      }
    }
  end

  defp phase3_settings_editor_assigns do
    %{
      myself: nil,
      current_tab: %{type: :settings, id: "settings"},
      settings_editor: %{
        selected_section: "project",
        search_query: "",
        active_sections: ["project"],
        project_visible?: true,
        editor_visible?: false,
        content_visible?: false,
        ai_visible?: false,
        publishing_visible?: false,
        data_visible?: false,
        technology_visible?: false,
        mcp_visible?: false,
        project: %{
          "name" => "Shell Project",
          "description" => "Project settings",
          "public_url" => "https://example.test",
          "main_language" => "en",
          "blog_languages" => ["en", "fr"],
          "default_author" => "Author",
          "max_posts_per_page" => 10,
          "blogmark_category" => "notes"
        },
        project_data_path: "/tmp/shell-project",
        supported_languages: ["en", "fr"],
        categories: [%{name: "notes"}, %{name: "posts"}]
      }
    }
  end

  defp phase3_tags_editor_assigns do
    %{
      myself: nil,
      tags_editor: %{
        selected_section: "cloud",
        tags: [],
        new_tag: %{"name" => "", "color" => "#3b82f6"},
        edit_draft: %{"name" => "news", "color" => "#3b82f6", "post_template_slug" => ""},
        selected: ["news", "updates"],
        merge_target: "news",
        templates: [%{slug: "post-template", title: "Post Template"}],
        colour_presets: BDS.Desktop.ShellLive.TagsEditor.colour_presets()
      }
    }
  end

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

  @tag :phase3
  test "phase 3 shell chrome renders utility-owned layout classes" do
    conn = Plug.Conn.put_private(build_conn(), :phoenix_endpoint, BDS.Desktop.Endpoint)
    {:ok, _view, html} = live_isolated(conn, BDS.Desktop.ShellLive)

    assert html =~ "activity-bar flex h-full shrink-0 flex-col items-center"
    assert html =~ "sidebar-shell flex min-w-0 shrink-0 overflow-hidden"
    assert html =~ "tab-bar-empty flex h-full items-center px-3 text-sm"
    assert html =~ "assistant-sidebar-shell flex min-w-0 shrink-0 overflow-hidden"
    assert html =~ "status-bar flex h-[22px] shrink-0 items-center justify-between"
  end

  @tag :phase3
  test "phase 3 editors and shared surfaces render utility-owned layouts" do
    post_html =
      render_component(&BDS.Desktop.ShellLive.PostEditor.render/1, phase3_post_editor_assigns())

    media_html =
      render_component(&BDS.Desktop.ShellLive.MediaEditor.render/1, phase3_media_editor_assigns())

    script_html =
      render_component(
        &BDS.Desktop.ShellLive.ScriptEditor.render/1,
        phase3_script_editor_assigns()
      )

    template_html =
      render_component(
        &BDS.Desktop.ShellLive.TemplateEditor.render/1,
        phase3_template_editor_assigns()
      )

    chat_html =
      render_component(&BDS.Desktop.ShellLive.ChatEditor.render/1, phase3_chat_editor_assigns())

    menu_html =
      render_component(&BDS.Desktop.ShellLive.MenuEditor.render/1, phase3_menu_editor_assigns())

    settings_html =
      render_component(
        &BDS.Desktop.ShellLive.SettingsEditor.render/1,
        phase3_settings_editor_assigns()
      )

    tags_html =
      render_component(&BDS.Desktop.ShellLive.TagsEditor.render/1, phase3_tags_editor_assigns())

    assert post_html =~ "post-editor ui-editor-shell flex h-full min-h-0 flex-col"

    assert post_html =~
             "editor-header ui-editor-header flex shrink-0 items-start justify-between gap-3"

    assert post_html =~ "editor-field ui-field-stack flex flex-col gap-1.5"
    assert post_html =~ "editor-toolbar ui-toolbar flex items-center gap-3"

    assert media_html =~ "media-editor ui-editor-shell flex h-full min-h-0 flex-col"
    assert media_html =~ "editor-content media-editor grid min-h-0 flex-1 gap-4 overflow-auto p-4"

    assert script_html =~ "scripts-view-shell ui-editor-shell flex h-full min-h-0 flex-col"
    assert script_html =~ "flex min-h-0 flex-1 flex-col gap-4 overflow-hidden p-4"

    assert template_html =~ "templates-view-shell ui-editor-shell flex h-full min-h-0 flex-col"
    assert template_html =~ "flex min-h-0 flex-1 flex-col gap-4 overflow-hidden p-4"

    assert chat_html =~ "chat-panel ui-editor-shell flex h-full min-h-0 flex-col"
    assert chat_html =~ "chat-panel-header flex shrink-0 items-center justify-between gap-3"

    assert menu_html =~ "menu-editor-view ui-editor-shell flex h-full min-h-0 flex-col p-4"
    assert menu_html =~ "menu-editor-toolbar ui-toolbar flex flex-wrap items-center gap-2"

    assert settings_html =~
             "settings-view-shell ui-editor-shell flex h-full min-h-0 flex-col overflow-hidden"

    assert settings_html =~ "settings-header flex shrink-0 items-center justify-between gap-3"

    assert tags_html =~ "tags-view-shell flex h-full min-h-0 flex-col overflow-hidden"
    assert tags_html =~ "tag-form-row flex flex-wrap items-center gap-3"
  end

  @tag :phase4
  test "phase 4 shared primitives render normalized classes" do
    conn = Plug.Conn.put_private(build_conn(), :phoenix_endpoint, BDS.Desktop.Endpoint)
    {:ok, view, _shell_html} = live_isolated(conn, BDS.Desktop.ShellLive)

    post_html =
      render_component(&BDS.Desktop.ShellLive.PostEditor.render/1, phase3_post_editor_assigns())

    media_html =
      render_component(&BDS.Desktop.ShellLive.MediaEditor.render/1, phase3_media_editor_assigns())

    script_html =
      render_component(
        &BDS.Desktop.ShellLive.ScriptEditor.render/1,
        phase3_script_editor_assigns()
      )

    template_html =
      render_component(
        &BDS.Desktop.ShellLive.TemplateEditor.render/1,
        phase3_template_editor_assigns()
      )

    settings_html =
      render_component(
        &BDS.Desktop.ShellLive.SettingsEditor.render/1,
        phase3_settings_editor_assigns()
      )

    tags_html =
      render_component(&BDS.Desktop.ShellLive.TagsEditor.render/1, phase3_tags_editor_assigns())

    panel_html =
      render_component(&BDS.Desktop.ShellLive.PanelRenderer.render_panel_body/1, %{
        current_tab: %{type: :dashboard, id: "dashboard"},
        task_status: %{tasks: []},
        output_entries: [],
        workbench: %{panel: %{active_tab: :tasks}}
      })

    assert post_html =~ ~s(class="status-badge ui-badge)
    assert post_html =~ ~s(class="success ui-button ui-button-primary)
    assert post_html =~ ~s(class="secondary danger ui-button ui-button-secondary ui-button-danger)
    assert post_html =~ ~s(class="post-editor-input ui-input)
    assert post_html =~ ~s(class="post-editor-textarea post-editor-excerpt ui-textarea)
    assert post_html =~ "ui-tab ui-tab-active ui-editor-tab-current"

    assert media_html =~ ~s(class="secondary quick-actions-btn ui-button ui-button-secondary)
    assert media_html =~ ~s(class="post-editor-input ui-input disabled ui-input-disabled)
    assert media_html =~ ~s(class="post-editor-textarea ui-textarea)

    assert script_html =~ ~s(class="secondary scripts-save-button ui-button ui-button-secondary)
    assert script_html =~ ~s(class="status-badge ui-badge)
    assert script_html =~ ~s(class="ui-input")

    assert template_html =~
             ~s(class="secondary templates-save-button ui-button ui-button-secondary)

    assert template_html =~ ~s(class="status-badge ui-badge)
    assert template_html =~ ~s(class="ui-input")

    assert settings_html =~ ~s(class="ui-input")
    assert settings_html =~ ~s(class="primary ui-button ui-button-primary")
    assert settings_html =~ ~s(class="secondary ui-button ui-button-secondary")

    assert tags_html =~ ~s(class="tags-empty-state ui-empty-state flex flex-col gap-3")
    assert tags_html =~ ~s(class="secondary ui-button ui-button-secondary")
    assert tags_html =~ ~s(class="primary ui-button ui-button-primary")
    assert tags_html =~ ~s(class="danger ui-button ui-button-danger")
    assert tags_html =~ ~s(class="ui-input")

    shell_html =
      view
      |> element("[data-testid='toggle-panel']")
      |> render_click()

    assert shell_html =~ ~s(class="panel-tab ui-tab ui-tab-active)
    assert panel_html =~ ~s(class="panel-entry ui-panel-entry panel-empty-state ui-empty-state)
  end

  @tag :phase5
  test "phase 5 desktop-specific surfaces keep shell, media, menu, and chat contracts" do
    conn = Plug.Conn.put_private(build_conn(), :phoenix_endpoint, BDS.Desktop.Endpoint)
    {:ok, _view, shell_html} = live_isolated(conn, BDS.Desktop.ShellLive)

    media_html =
      render_component(&BDS.Desktop.ShellLive.MediaEditor.render/1, phase3_media_editor_assigns())

    chat_html =
      render_component(&BDS.Desktop.ShellLive.ChatEditor.render/1, phase3_chat_editor_assigns())

    menu_html =
      render_component(&BDS.Desktop.ShellLive.MenuEditor.render/1, phase3_menu_editor_assigns())

    assert shell_html =~ ~s(class="assistant-sidebar-context flex shrink-0 flex-col gap-2")
    assert shell_html =~ ~s(class="assistant-sidebar-prompt min-h-[8rem] w-full resize-y")
    assert shell_html =~ ~s(class="assistant-sidebar-start-button ui-button ui-button-primary")
    assert shell_html =~ ~s(class="assistant-sidebar-welcome min-h-0 flex-1 overflow-auto")

    assert media_html =~
             "class=\"editor-content media-editor grid min-h-0 flex-1 gap-4 overflow-auto p-4 xl:grid-cols-[minmax(320px,1fr)_minmax(0,1.2fr)]\""

    assert media_html =~ "class=\"media-preview flex min-h-[16rem] items-center justify-center\""
    assert media_html =~ ~s(class="media-details min-w-0")

    assert chat_html =~ ~s(class="chat-panel ui-editor-shell flex h-full min-h-0 flex-col")

    assert chat_html =~
             ~s(class="chat-model-selector-button chat-model-selector-inline ui-button ui-button-secondary inline-flex items-center gap-2")

    assert chat_html =~
             ~s(class="chat-input-container ui-field-stack flex shrink-0 flex-col gap-3")

    assert chat_html =~ ~s(class="chat-input-wrapper flex items-end gap-2")

    assert menu_html =~
             ~s(class="menu-editor-view ui-editor-shell flex h-full min-h-0 flex-col p-4")

    assert menu_html =~
             ~s(class="menu-editor-toolbar ui-toolbar flex flex-wrap items-center gap-2")

    assert menu_html =~
             ~s(class="menu-editor-empty flex min-h-0 flex-1 items-center justify-center")
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

  defmodule GatedChatServer do
    @moduledoc false
    use Plug.Router
    import Phoenix.ConnTest, except: [post: 2]

    plug(:match)
    plug(:dispatch)

    def hold_gate do
      case GenServer.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      Agent.start_link(fn -> :hold end, name: __MODULE__)
    end

    def release_gate, do: Agent.update(__MODULE__, fn _ -> :release end)

    post "/v1/chat/completions" do
      wait_for_release()

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

    defp wait_for_release do
      case GenServer.whereis(__MODULE__) do
        nil ->
          Process.sleep(:infinity)

        _pid ->
          case Agent.get(__MODULE__, & &1) do
            :release -> :ok
            :hold -> Process.sleep(50) && wait_for_release()
          end
      end
    end
  end

  defmodule TitleChatServer do
    use Plug.Router
    import Phoenix.ConnTest, except: [post: 2]

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(request_body)
      send(Application.fetch_env!(:bds, :test_pid), {:title_chat_request, request})

      content =
        if Enum.any?(request["messages"] || [], fn message ->
             String.contains?(message["content"] || "", "Generate an ultra-short title")
           end) do
          "Posts 2026"
        else
          "Ich habe die Posts pro Monat ermittelt."
        end

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => content}}],
          "usage" => %{"prompt_tokens" => 8, "completion_tokens" => 5}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  defmodule AiSuggestionsServer do
    use Plug.Router
    import Phoenix.ConnTest, except: [post: 2]

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(request_body)
      send(Application.fetch_env!(:bds, :test_pid), {:ai_suggestions_request, request})

      operation = get_in(request, ["messages", Access.at(0), "content"]) || ""

      content =
        cond do
          String.contains?(operation, "image") ->
            Jason.encode!(%{
              "title" => "AI Image Title",
              "alt" => "AI Alt Text",
              "caption" => "AI Caption"
            })

          true ->
            Jason.encode!(%{
              "title" => "AI Suggested Title",
              "excerpt" => "AI Suggested Excerpt",
              "slug" => "ai-suggested-slug"
            })
        end

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => content}}],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    Enum.each(BDS.Tasks.list_running_tasks(), fn task ->
      BDS.Tasks.cancel_task(task.id)
    end)

    if :ets.whereis(:bds_ai_in_flight) != :undefined do
      Enum.each(:ets.tab2list(:bds_ai_in_flight), fn {_conversation_id, pid} ->
        Process.exit(pid, :kill)
      end)
    end

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.TCP.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.TCP.TaskSupervisor, pid)
    end

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.Tasks.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)
    end

    Process.sleep(100)

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

    assert Repo.get(BDS.AI.ChatConversation, created_chat.id)
    assert html =~ "confirm-delete-modal"
    assert html =~ created_chat.title

    html = render_click(view, "overlay_confirm", %{})

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

  test "blogmark deep link creates a draft post and opens it in the editor", %{project: project} do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
    post_count_before = Repo.aggregate(Post, :count, :id)

    url =
      "bds2://new-post?title=" <>
        URI.encode_www_form("Saved From Browser") <>
        "&url=" <> URI.encode_www_form("https://example.com/article")

    send(view.pid, {:blogmark_deep_link, url})
    html = render(view)

    assert Repo.aggregate(Post, :count, :id) == post_count_before + 1

    created_post = Repo.get_by!(Post, title: "Saved From Browser")
    assert created_post.project_id == project.id
    assert created_post.status == :draft
    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="#{created_post.id}")
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

  test "tags sidebar selections expose a scroll target for the tags editor" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_click(view, "select_view", %{"view" => "tags"})

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='tags-merge']")
      |> render_click()

    assert html =~ ~s(data-testid="tags-editor")
    assert html =~ ~s(phx-hook="TagsSectionScroll")
    assert html =~ ~s(data-selected-tags-section="merge")
    assert html =~ ~s(data-tags-scroll-target="tags-section-merge")
  end

  test "tags discover materializes post tags and enables merge from the tags editor", %{
    project: project
  } do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Tagged Post",
               content: "Body",
               tags: ["Alpha", "Beta"]
             })

    assert Tags.list_tags(project.id) == []

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_click(view, "select_view", %{"view" => "tags"})

    _html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='tags-cloud']")
      |> render_click()

    html =
      view
      |> element("#tags-section-sync button[phx-click='sync_tags_editor']")
      |> render_click()

    assert Enum.map(Tags.list_tags(project.id), & &1.name) == ["Alpha", "Beta"]
    assert html =~ "Alpha"
    assert html =~ "Beta"

    _html =
      view
      |> element(
        "#tags-editor-shell button[phx-click='toggle_tag_selection'][phx-value-name='Alpha']"
      )
      |> render_click()

    _html =
      view
      |> element(
        "#tags-editor-shell button[phx-click='toggle_tag_selection'][phx-value-name='Beta']"
      )
      |> render_click()

    _html =
      view
      |> element("#tags-editor-shell select[phx-change='change_merge_target']")
      |> render_change(%{"target" => "Alpha"})

    html =
      view
      |> element("#tags-editor-shell button[phx-click='merge_tags_editor']")
      |> render_click()

    assert Enum.map(Tags.list_tags(project.id), & &1.name) == ["Alpha"]
    assert Repo.get!(Post, post.id).tags == ["Alpha"]
    assert html =~ "Alpha"
  end

  test "database-backed sidebar entries require confirmation before deletion", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Sidebar Delete Post",
               content: "delete me"
             })

    media_source_path = Path.join(temp_dir, "sidebar-delete-media.txt")
    File.write!(media_source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: media_source_path,
               title: "Sidebar Delete Media"
             })

    assert {:ok, script} =
             Scripts.create_script(%{
               project_id: project.id,
               title: "Sidebar Delete Script",
               kind: :utility,
               content: "print(\"delete\")",
               entrypoint: "main",
               enabled: true
             })

    assert {:ok, template} =
             Templates.create_template(%{
               project_id: project.id,
               title: "Sidebar Delete Template",
               kind: :post,
               content: "<article>{{ post.content }}</article>",
               enabled: true
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Sidebar Delete Chat"})

    assert {:ok, definition} =
             ImportDefinitions.create_definition(%{
               project_id: project.id,
               name: "Sidebar Delete Import"
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    cases = [
      %{
        view: "posts",
        id: post.id,
        title: post.title,
        testid: "sidebar-delete-post",
        exists?: fn -> Repo.get(Post, post.id) != nil end
      },
      %{
        view: "media",
        id: media.id,
        title: media.title,
        testid: "sidebar-delete-media",
        exists?: fn -> Repo.get(BDS.Media.Media, media.id) != nil end
      },
      %{
        view: "scripts",
        id: script.id,
        title: script.title,
        testid: "sidebar-delete-script",
        exists?: fn -> Repo.get(BDS.Scripts.Script, script.id) != nil end
      },
      %{
        view: "templates",
        id: template.id,
        title: template.title,
        testid: "sidebar-delete-template",
        exists?: fn -> Repo.get(BDS.Templates.Template, template.id) != nil end
      },
      %{
        view: "chat",
        id: conversation.id,
        title: conversation.title,
        testid: "sidebar-delete-chat",
        exists?: fn -> Repo.get(BDS.AI.ChatConversation, conversation.id) != nil end
      },
      %{
        view: "import",
        id: definition.id,
        title: definition.name,
        testid: "sidebar-delete-import",
        exists?: fn -> Repo.get(ImportDefinitions.ImportDefinition, definition.id) != nil end
      }
    ]

    Enum.each(cases, fn sidebar_case ->
      html = render_click(view, "select_view", %{"view" => sidebar_case.view})

      assert html =~ ~s(data-testid="#{sidebar_case.testid}")

      html =
        view
        |> element("[data-testid='#{sidebar_case.testid}'][data-item-id='#{sidebar_case.id}']")
        |> render_click()

      assert sidebar_case.exists?.()
      assert html =~ "confirm-delete-modal"
      assert html =~ sidebar_case.title

      html = render_click(view, "overlay_confirm", %{})

      refute sidebar_case.exists?.()
      refute html =~ sidebar_case.title
    end)
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

    assert html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

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

    assert html =~ ~s(class="sidebar-shell flex min-w-0 shrink-0 overflow-hidden is-hidden")

    html =
      view
      |> element("[data-testid='toggle-sidebar']")
      |> render_click()

    refute html =~ ~s(class="sidebar-shell flex min-w-0 shrink-0 overflow-hidden is-hidden")

    html =
      view
      |> element("[data-testid='toggle-panel']")
      |> render_click()

    assert html =~ ~s(data-region="panel")

    refute html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

    assert html =~ ~s(data-testid="panel-close")

    html =
      view
      |> element("[data-testid='panel-close']")
      |> render_click()

    assert html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

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
    assert html =~ ~s(class="tab-bar-empty flex h-full items-center px-3 text-sm")
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

    assert html =~ ~s(class="sidebar-shell flex min-w-0 shrink-0 overflow-hidden is-hidden")

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

  test "native metadata diff action queues the maintenance task" do
    :ok = BDS.Tasks.clear_finished()

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    existing_ids = MapSet.new(Enum.map(BDS.Tasks.list_tasks(), & &1.id))

    _html = render_hook(view, "native_menu_action", %{"action" => "metadata_diff"})

    assert %{} = new_task!(existing_ids, "Metadata Diff")
  end

  test "native new post action reuses the sidebar create flow" do
    count_before = Repo.aggregate(Post, :count, :id)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_hook(view, "native_menu_action", %{"action" => "new_post"})

    assert Repo.aggregate(Post, :count, :id) == count_before + 1
  end

  test "native save action persists the active post editor", %{project: project} do
    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Draft Shell Post",
        content: "Initial body",
        excerpt: "Initial excerpt"
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

    _html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Saved Through Menu",
          content: "Saved body",
          excerpt: "Saved excerpt",
          tags: "",
          categories: "",
          author: "",
          language: "en",
          do_not_translate: "false"
        }
      })
      |> render_change()

    _html = render_hook(view, "native_menu_action", %{"action" => "save"})
    _html = render(view)

    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Saved Through Menu"
    assert saved_post.content == "Saved body"
    assert saved_post.excerpt == "Saved excerpt"
  end

  test "post editor auto-saves after idle timer fires", %{project: project} do
    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Auto-save Draft",
        content: "Original body",
        excerpt: "Original excerpt"
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

    _html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Auto-saved Title",
          content: "Auto-saved body",
          excerpt: "Auto-saved excerpt",
          tags: "",
          categories: "",
          author: "",
          language: "en",
          do_not_translate: "false"
        }
      })
      |> render_change()

    send_and_await(view, {:auto_save_fire, :post, post.id})
    _html = render(view)

    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Auto-saved Title"
    assert saved_post.content == "Auto-saved body"
    assert saved_post.excerpt == "Auto-saved excerpt"
  end

  test "post editor auto-save timer fires and persists after delay", %{project: project} do
    Application.put_env(:bds, :auto_save_delay, 100)
    on_exit(fn -> Application.delete_env(:bds, :auto_save_delay) end)

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Timer Draft",
        content: "Body",
        excerpt: ""
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

    _html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Timer Changed Title",
          content: "Body",
          excerpt: "",
          tags: "",
          categories: "",
          author: "",
          language: "en",
          do_not_translate: "false"
        }
      })
      |> render_change()

    Process.sleep(200)
    _html = render(view)

    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Timer Changed Title"
  end

  test "post editor auto-saves dirty content on tab switch", %{project: project} do
    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Tab-switch Draft",
        content: "Original body",
        excerpt: ""
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

    _html =
      view
      |> form("[data-testid='post-editor-form']", %{
        post_editor: %{
          title: "Unsaved Tab Title",
          content: "Unsaved body",
          excerpt: "",
          tags: "",
          categories: "",
          author: "",
          language: "en",
          do_not_translate: "false"
        }
      })
      |> render_change()

    _html =
      render_click(view, "select_tab", %{
        "type" => "dashboard",
        "id" => "dashboard"
      })

    _html = render(view)
    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Unsaved Tab Title"
    assert saved_post.content == "Unsaved body"
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
    assert Regex.match?(~r/class="tab [^"]*active[^"]*transient/, html)
  end

  test "workbench session restore renders documentation tab content" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.open_tab(:documentation, "documentation", :pin)
      |> Session.serialize()

    _html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})

    assert has_element?(view, ".tab[data-tab-type='documentation'] .tab-title", "Documentation")
    assert has_element?(view, "[data-testid='help-documentation']")
    assert has_element?(view, ".documentation-content.markdown-body .documentation-article")
    assert render(view) =~ "bDS2 User Guide"
  end

  test "workbench session restore renders api documentation tab content" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.open_tab(:api_documentation, "api_documentation", :pin)
      |> Session.serialize()

    _html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})

    assert has_element?(
             view,
             ".tab[data-tab-type='api_documentation'] .tab-title",
             "Api Documentation"
           )

    assert has_element?(view, "[data-testid='help-api-documentation']")
    assert has_element?(view, ".documentation-content.markdown-body .documentation-article")
    assert render(view) =~ "API Documentation"
    assert render(view) =~ "local result = bds.posts.get"
  end

  test "workbench session restore rehydrates chat tab titles from stored conversations" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Editorial Plan"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.open_tab(:chat, conversation.id, :pin)
      |> Session.serialize()

    _html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})

    assert has_element?(
             view,
             ".tab[data-tab-type='chat'][data-tab-id='#{conversation.id}'] .tab-title",
             "Editorial Plan"
           )

    assert has_element?(view, ".chat-panel-title-main", "Editorial Plan")
  end

  test "workbench session restore rehydrates entity tab titles from backing records", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} = Posts.create_post(%{project_id: project.id, title: "Restored Post"})

    source_path = Path.join(temp_dir, "restored-media.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Restored Media"
             })

    assert {:ok, script} =
             Scripts.create_script(%{
               project_id: project.id,
               title: "Restored Script",
               kind: :utility,
               content: "print(\"ok\")",
               entrypoint: "main",
               enabled: true
             })

    assert {:ok, template} =
             Templates.create_template(%{
               project_id: project.id,
               title: "Restored Template",
               kind: :post,
               content: "",
               enabled: true
             })

    assert {:ok, definition} =
             ImportDefinitions.create_definition(%{
               project_id: project.id,
               name: "Restored Import"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Restored Chat"})

    posts_dir = Path.join(temp_dir, "posts")
    File.mkdir_p!(posts_dir)

    git_file_path = Path.join(posts_dir, "restore.md")
    File.write!(git_file_path, "Old content\n")
    init_git_repo!(temp_dir, "initial")
    File.write!(git_file_path, "New content\n")

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    session_payload =
      Workbench.new()
      |> Workbench.open_tab(:post, post.id, :pin)
      |> Workbench.open_tab(:media, media.id, :pin)
      |> Workbench.open_tab(:scripts, script.id, :pin)
      |> Workbench.open_tab(:templates, template.id, :pin)
      |> Workbench.open_tab(:import, definition.id, :pin)
      |> Workbench.open_tab(:chat, conversation.id, :pin)
      |> Workbench.open_tab(:git_diff, "git-working-tree", :pin)
      |> Session.serialize()

    _html = render_hook(view, "restore_workbench_session", %{"session" => session_payload})

    assert has_element?(
             view,
             ".tab[data-tab-type='post'][data-tab-id='#{post.id}'] .tab-title",
             "Restored Post"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='media'][data-tab-id='#{media.id}'] .tab-title",
             "Restored Media"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='scripts'][data-tab-id='#{script.id}'] .tab-title",
             "Restored Script"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='templates'][data-tab-id='#{template.id}'] .tab-title",
             "Restored Template"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='import'][data-tab-id='#{definition.id}'] .tab-title",
             "Restored Import"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='chat'][data-tab-id='#{conversation.id}'] .tab-title",
             "Restored Chat"
           )

    assert has_element?(
             view,
             ".tab[data-tab-type='git_diff'][data-tab-id='git-working-tree'] .tab-title",
             "Working tree"
           )
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
    assert html =~ "Online Chat Reasoning"
    assert html =~ "Offline Chat Reasoning"
    refute html =~ "Mistral API Key"
    refute html =~ "Anthropic / Online API Key"

    _html =
      view
      |> element("#settings-editor-shell form[phx-change='change_settings_ai']")
      |> render_change(%{
        "settings_ai" => %{
          "online_url" => "https://api.example.test/v1",
          "online_api_key" => "online-secret",
          "online_chat_model" => "gpt-4.1",
          "online_chat_tools" => "true",
          "online_chat_disable_reasoning" => "true",
          "online_title_model" => "gpt-4.1-mini",
          "online_image_analysis_model" => "gpt-4.1-vision",
          "offline_url" => "http://localhost:11434/v1",
          "offline_api_key" => "",
          "offline_chat_model" => "llama3.3",
          "offline_chat_tools" => "true",
          "offline_chat_disable_reasoning" => "true",
          "offline_title_model" => "llama3.2",
          "offline_image_analysis_model" => "llava:latest",
          "offline_mode" => "true",
          "system_prompt" => "You are the local test prompt."
        }
      })

    _html =
      view
      |> element("#settings-editor-shell button[phx-click='save_settings_ai']")
      |> render_click()

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

    assert %{supports_tool_calls: true, disables_reasoning: true} =
             BDS.AI.Catalog.model_capabilities("gpt-4.1")

    assert %{supports_tool_calls: true, disables_reasoning: true} =
             BDS.AI.Catalog.model_capabilities("llama3.3")
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
      view
      |> element("#settings-editor-shell form[phx-change='change_settings_ai']")
      |> render_change(%{
        "settings_ai" => %{
          "online_url" => "https://api.example.test/v1",
          "offline_url" => "http://localhost:11434/v1"
        }
      })

    html =
      view
      |> element(
        "#settings-editor-shell button[phx-click='refresh_settings_ai_models'][phx-value-endpoint='online']"
      )
      |> render_click()

    assert html =~ ~s(<option value="gpt-4.1"></option>)
    assert html =~ ~s(<option value="gpt-4.1-mini"></option>)

    html =
      view
      |> element(
        "#settings-editor-shell button[phx-click='refresh_settings_ai_models'][phx-value-endpoint='airplane']"
      )
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
    assert Regex.match?(~r/class="tab [^"]*active[^"]*transient/, html)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => "post-1",
        "title" => "First Post",
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-tab-id="post-1")
    refute Regex.match?(~r/class="tab [^"]*active[^"]*transient/, html)

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

    assert html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

    html = render_keydown(view, "shortcut", %{key: "b", meta: true})
    assert html =~ ~s(class="sidebar-shell flex min-w-0 shrink-0 overflow-hidden is-hidden")

    html = render_keydown(view, "shortcut", %{key: "j", meta: true})

    refute html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

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

    assert html =~ ~s(class="sidebar-shell flex min-w-0 shrink-0 overflow-hidden is-hidden")
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
    assert html =~ ~s(class="sidebar-section-header flex items-center justify-between gap-2")
    assert html =~ ~s(class="sidebar-actions flex items-center gap-1")
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

    refute html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

    html =
      view
      |> element("[data-testid='status-task-button']")
      |> render_click()

    refute html =~
             ~s(class="panel-shell flex min-h-0 shrink-0 flex-col overflow-hidden is-hidden")

    assert Regex.match?(
             ~r/<button class="panel-tab [^"]*ui-tab[^"]*active" type="button" phx-click="select_panel_tab" phx-value-tab="tasks">/,
             html
           )

    assert html =~ ~s(class="task-list flex flex-col gap-2") or
             html =~ ~s(class="panel-entry ui-panel-entry panel-empty-state ui-empty-state")
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

    view
    |> element(
      "[data-testid='metadata-diff-repair-button'][data-direction='file_to_db'][data-field='title']"
    )
    |> render_click()

    html = render(view)
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

    view
    |> element("[data-testid='metadata-diff-import-button']")
    |> render_click()

    html = render(view)
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

    view
    |> element(
      "[data-testid='metadata-diff-repair-button'][data-direction='file_to_db'][data-field='content_hash']"
    )
    |> render_click()

    html = render(view)
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

    html =
      view
      |> element("[data-testid='post-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"
    assert html =~ "quick-action-item"
    assert html =~ "quick-actions-divider"

    html =
      view
      |> element("[phx-click='set_post_editor_mode'][phx-value-mode='preview']")
      |> render_click()

    assert html =~ ~s(data-testid="post-editor-preview")
    assert html =~ "editor-preview-frame"
    refute html =~ ~s(data-testid="post-editor-content")

    html =
      view
      |> element("[phx-click='set_post_editor_mode'][phx-value-mode='markdown']")
      |> render_click()

    assert html =~ ~s(data-testid="post-editor-content")
    assert html =~ ~s(data-monaco-language="markdown-with-macros")
    assert html =~ ~s(phx-hook="MonacoEditor")
    refute html =~ "post-editor-markdown-highlight"

    _html =
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

    html = render(view)
    assert Regex.match?(~r/class="tab [^"]*active[^"]*dirty/, html)
    assert html =~ "Updated Shell Post"

    _html = render_hook(view, "native_menu_action", %{"action" => "save"})
    _html = render(view)

    saved_post = Posts.get_post!(post.id)
    assert saved_post.title == "Updated Shell Post"
    assert saved_post.content == "Updated body"
    assert saved_post.excerpt == "Updated excerpt"
    assert saved_post.tags == ["alpha", "beta"]
    assert saved_post.categories == ["notes", "guides"]
    assert saved_post.author == "Ada Lovelace"
    assert saved_post.language == "de"

    html =
      view
      |> element("[data-testid='post-publish-button']")
      |> render_click()

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

    _html = render_hook(view, "native_menu_action", %{"action" => "save"})
    _html = render(view)
    assert Posts.get_post!(post.id).status == :draft

    html =
      view
      |> element("[data-testid='post-discard-button']")
      |> render_click()

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

  test "ai suggestions overlay is gated by offline mode for posts", %{project: project} do
    assert :ok = AI.set_airplane_mode(true)

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Offline Post",
        content: "Some content"
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

    html =
      view
      |> element("[data-testid='post-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    refute html =~ "ai-suggestions-modal"
    assert html =~ "Automatic AI actions stay gated by airplane mode"
  end

  test "ai suggestions overlay fetches async results for posts when online", %{project: project} do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: AiSuggestionsServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "test-secret",
               model: "gpt-test"
             })

    assert :ok = AI.put_model_preference(:title, "gpt-test")

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Online Post",
        content: "Some content for AI analysis"
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

    html =
      view
      |> element("[data-testid='post-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    assert html =~ "ai-suggestions-modal"
    assert html =~ "Loading"

    assert_receive {:ai_suggestions_request, _request}, 2_000

    Process.sleep(200)
    html = render(view)

    assert html =~ "AI Suggested Title"
    assert html =~ "AI Suggested Excerpt"
    assert html =~ "ai-suggested-slug"
    refute html =~ "Loading"
  end

  test "ai suggestions overlay sends project main language for posts", %{project: project} do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: AiSuggestionsServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "test-secret",
               model: "gpt-test"
             })

    assert :ok = AI.put_model_preference(:title, "gpt-test")

    assert {:ok, _metadata} = Metadata.update_project_metadata(project.id, %{main_language: "de"})

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "German Post",
        content: "Some content for AI analysis"
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

    html =
      view
      |> element("[data-testid='post-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    assert html =~ "ai-suggestions-modal"

    assert_receive {:ai_suggestions_request, request}, 2_000

    system_message = get_in(request, ["messages", Access.at(0), "content"]) || ""
    user_message = get_in(request, ["messages", Access.at(1), "content"]) || ""
    assert system_message =~ "German"
    assert user_message =~ "German"
  end

  test "ai suggestions overlay is gated by offline mode for media", %{project: project} do
    assert :ok = AI.set_airplane_mode(true)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    media_source_path = Path.join(temp_dir, "offline-media.jpg")
    File.write!(media_source_path, "fake image body")

    {:ok, media} =
      Media.import_media(%{
        project_id: project.id,
        source_path: media_source_path,
        title: "Offline Media"
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-testid="media-editor")

    html =
      view
      |> element("[data-testid='media-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    refute html =~ "ai-suggestions-modal"
    assert html =~ "Automatic AI actions stay gated by airplane mode"
  end

  test "ai suggestions overlay fetches async results for media when online", %{project: project} do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: AiSuggestionsServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "test-secret",
               model: "gpt-test"
             })

    assert :ok = AI.put_model_preference(:image_analysis, "gpt-test")
    assert :ok = AI.put_model_capabilities("gpt-test", %{supports_attachment: true})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    media_source_path = Path.join(temp_dir, "online-media.jpg")
    File.write!(media_source_path, "fake image body")

    {:ok, media} =
      Media.import_media(%{
        project_id: project.id,
        source_path: media_source_path,
        title: "Online Media"
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-testid="media-editor")

    html =
      view
      |> element("[data-testid='media-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    assert html =~ "ai-suggestions-modal"
    assert html =~ "Loading"

    assert_receive {:ai_suggestions_request, _request}, 2_000

    Process.sleep(200)
    html = render(view)

    assert html =~ "AI Image Title"
    assert html =~ "AI Alt Text"
    assert html =~ "AI Caption"
    refute html =~ "Loading"
  end

  test "ai suggestions overlay sends project main language for media", %{project: project} do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: AiSuggestionsServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "test-secret",
               model: "gpt-test"
             })

    assert :ok = AI.put_model_preference(:image_analysis, "gpt-test")
    assert :ok = AI.put_model_capabilities("gpt-test", %{supports_attachment: true})

    assert {:ok, _metadata} = Metadata.update_project_metadata(project.id, %{main_language: "de"})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    media_source_path = Path.join(temp_dir, "german-media.jpg")
    File.write!(media_source_path, "fake image body")

    {:ok, media} =
      Media.import_media(%{
        project_id: project.id,
        source_path: media_source_path,
        title: "German Media"
      })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "media",
        "id" => media.id,
        "title" => media.title,
        "subtitle" => "draft"
      })

    assert html =~ ~s(data-testid="media-editor")

    html =
      view
      |> element("[data-testid='media-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    assert html =~ "ai-suggestions-modal"

    assert_receive {:ai_suggestions_request, request}, 2_000

    system_message = get_in(request, ["messages", Access.at(0), "content"]) || ""
    user_message = Enum.at(request["messages"], 1)
    text_content = Enum.at(user_message["content"], 0)
    assert system_message =~ "German"
    assert text_content["text"] =~ "German"
  end

  test "ai suggestions async error closes overlay and shows toast", %{project: project} do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: AiSuggestionsServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert :ok = AI.set_airplane_mode(false)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "test-secret",
               model: "gpt-test"
             })

    assert :ok = AI.put_model_preference(:title, "gpt-test")

    {:ok, post} =
      Posts.create_post(%{
        project_id: project.id,
        title: "Error Post",
        content: "Some content"
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

    html =
      view
      |> element("[data-testid='post-editor'] .quick-actions-btn")
      |> render_click()

    assert html =~ "quick-actions-menu"

    html =
      view
      |> element("[phx-click='open_overlay'][phx-value-kind='ai_suggestions']")
      |> render_click()

    assert html =~ "ai-suggestions-modal"

    _ =
      capture_log(fn ->
        send(view.pid, {:ai_suggestions_error, :post, post.id, :test_error})
        render(view)
      end)

    html = render(view)

    assert html =~ "ai-suggestions-modal"
    assert html =~ "ai-suggestions-error"
    assert html =~ "test_error"
  end

  test "script and template editors surface lifecycle state, load published file content, and allow publishing drafts",
       %{project: project} do
    {:ok, draft_script} =
      Scripts.create_script(%{
        project_id: project.id,
        title: "Draft Utility",
        kind: :utility,
        content: "function main() return 'draft' end"
      })

    {:ok, published_script_seed} =
      Scripts.create_script(%{
        project_id: project.id,
        title: "Published Utility",
        kind: :utility,
        content: "function main() return 'published script' end"
      })

    assert {:ok, _published_script} = Scripts.publish_script(published_script_seed.id)
    published_script = Scripts.get_script(published_script_seed.id)

    {:ok, draft_template} =
      Templates.create_template(%{
        project_id: project.id,
        title: "Draft Template",
        kind: :post,
        content: "<article>draft template</article>"
      })

    {:ok, published_template_seed} =
      Templates.create_template(%{
        project_id: project.id,
        title: "Published Template",
        kind: :post,
        content: "<article>published template</article>"
      })

    assert {:ok, _published_template} = Templates.publish_template(published_template_seed.id)
    published_template = Templates.get_template(published_template_seed.id)

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    published_script_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "scripts",
        "id" => published_script.id,
        "title" => published_script.title,
        "subtitle" => "published"
      })

    assert published_script_html =~
             ~s(class="scripts-view-shell ui-editor-shell flex h-full min-h-0 flex-col")

    assert published_script_html =~ ~s(data-testid="script-editor")
    assert published_script_html =~ ~s(data-testid="script-status-badge")
    assert published_script_html =~ ~s(class="status-badge ui-badge status-published")

    assert published_script_html =~
             ~s(class="secondary scripts-save-button ui-button ui-button-secondary")

    assert published_script_html =~
             ~s(class="secondary scripts-run-button ui-button ui-button-secondary")

    assert published_script_html =~
             ~s(class="secondary scripts-check-button ui-button ui-button-secondary")

    assert published_script_html =~ "published"

    assert published_script_html =~ "published script"

    refute published_script_html =~ ~s(data-testid="script-publish-button")

    published_template_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "templates",
        "id" => published_template.id,
        "title" => published_template.title,
        "subtitle" => "published"
      })

    assert published_template_html =~
             ~s(class="templates-view-shell ui-editor-shell flex h-full min-h-0 flex-col")

    assert published_template_html =~ ~s(data-testid="template-editor")
    assert published_template_html =~ ~s(data-testid="template-status-badge")
    assert published_template_html =~ ~s(class="status-badge ui-badge status-published")

    assert published_template_html =~
             ~s(class="secondary templates-save-button ui-button ui-button-secondary")

    assert published_template_html =~
             ~s(class="secondary templates-validate-button ui-button ui-button-secondary")

    assert published_template_html =~ "published"

    assert published_template_html =~ "published template"

    refute published_template_html =~ ~s(data-testid="template-publish-button")

    draft_script_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "scripts",
        "id" => draft_script.id,
        "title" => draft_script.title,
        "subtitle" => "draft"
      })

    assert draft_script_html =~ ~s(data-testid="script-publish-button")
    assert draft_script_html =~ ~s(class="success ui-button ui-button-primary")

    draft_script_html =
      view
      |> element("[data-testid='script-publish-button']")
      |> render_click()

    assert Scripts.get_script(draft_script.id).status == :published
    refute draft_script_html =~ ~s(data-testid="script-publish-button")
    assert draft_script_html =~ ~s(data-testid="script-status-badge")
    assert draft_script_html =~ "published"

    draft_template_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "templates",
        "id" => draft_template.id,
        "title" => draft_template.title,
        "subtitle" => "draft"
      })

    assert draft_template_html =~ ~s(data-testid="template-publish-button")
    assert draft_template_html =~ ~s(class="success ui-button ui-button-primary")

    draft_template_html =
      view
      |> element("[data-testid='template-publish-button']")
      |> render_click()

    assert Templates.get_template(draft_template.id).status == :published
    refute draft_template_html =~ ~s(data-testid="template-publish-button")
    assert draft_template_html =~ ~s(data-testid="template-status-badge")
    assert draft_template_html =~ "published"
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

    html =
      view
      |> element("[data-testid='media-editor'] .quick-actions-btn")
      |> render_click()

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

    _html =
      view
      |> element("[data-testid='media-save-button']")
      |> render_click()

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

    assert html =~
             "class=\"editor-content media-editor grid min-h-0 flex-1 gap-4 overflow-auto p-4 xl:grid-cols-[minmax(320px,1fr)_minmax(0,1.2fr)]\""

    assert html =~ ~s(class="quick-actions-wrapper relative")
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

    html =
      view
      |> element("[phx-click='edit_media_translation'][phx-value-language='de']")
      |> render_click()

    assert html =~ ~s(class="translation-modal-backdrop")

    assert html =~
             ~s(class="translation-modal flex max-h-[80vh] w-full max-w-2xl flex-col overflow-hidden")

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

    assert settings_html =~
             ~s(class="settings-view-shell ui-editor-shell flex h-full min-h-0 flex-col overflow-hidden")

    assert settings_html =~ ~s(class="setting-section ui-section-card")
    refute settings_html =~ "Desktop workbench content routed through the Elixir shell."

    tags_html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "tags",
        "id" => "tags",
        "title" => "Tags",
        "subtitle" => "Manage tags"
      })

    assert tags_html =~ ~s(class="tags-view-shell flex h-full min-h-0 flex-col overflow-hidden")
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

    assert script_html =~
             ~s(class="scripts-view-shell ui-editor-shell flex h-full min-h-0 flex-col")

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

    assert template_html =~
             ~s(class="templates-view-shell ui-editor-shell flex h-full min-h-0 flex-col")

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

    assert chat_html =~ ~s(class="chat-panel ui-editor-shell flex h-full min-h-0 flex-col")

    assert chat_html =~
             ~s(class="chat-input-container ui-field-stack flex shrink-0 flex-col gap-3")

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
    assert html =~ ~s(class="chat-model-selector-wrap relative shrink-0")

    assert html =~
             ~s(class="chat-model-selector-button chat-model-selector-inline ui-button ui-button-secondary inline-flex items-center gap-2")

    refute html =~ ~s(class="chat-panel-header-actions")

    css = desktop_css_source()
    assert css =~ ".chat-model-selector-wrap"
    assert css =~ "left: 0;"
    assert css =~ "right: auto;"

    refute css =~
             ".chat-model-selector-menu {\n  position: absolute;\n  top: calc(100% + 4px);\n  right: 16px;"

    assert css =~ ".chat-panel .chat-model-selector-button.chat-model-selector-inline"
    assert css =~ ".chat-panel .chat-model-selector-caret"
    assert css =~ "position: static;"
  end

  test "chat editor model selector uses effective model for new chats and persists selection" do
    assert :ok = AI.set_airplane_mode(true)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:airplane, %{
               url: "http://localhost:11434/v1",
               api_key: nil,
               model: "llama-default"
             })

    assert :ok = AI.put_model_preference(:airplane_chat, "llama-current")
    assert {:ok, conversation} = AI.start_chat(%{title: "New Chat"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => "chat"
      })

    assert html =~ ~s(data-testid="chat-model-selector-button")
    assert html =~ "llama-current"
    refute html =~ ~s(<span>New Chat</span><span class="chat-model-selector-caret">▾</span>)

    selector_html =
      view
      |> element("[data-testid='chat-model-selector-button']")
      |> render_click()

    assert selector_html =~
             ~s(class="chat-model-selector-menu ui-dropdown-menu absolute right-0 top-full z-10 mt-2 flex min-w-56 flex-col")

    assert selector_html =~ ~s(data-testid="chat-model-selector-option")
    assert selector_html =~ "llama-current"

    css = desktop_css_source()
    assert css =~ ".chat-panel-title {"
    assert css =~ "overflow: visible;"

    refute css =~
             ".chat-panel-title {\n  flex: 1;\n  min-width: 0;\n  display: flex;\n  align-items: center;\n  gap: 10px;\n  overflow: hidden;"

    view
    |> element("button[phx-value-model='llama-default']")
    |> render_click()

    assert AI.get_chat_conversation(conversation.id).model == "llama-default"
    assert render(view) =~ "llama-default"
  end

  test "chat editor updates the visible new-chat title after the first turn" do
    Application.put_env(:bds, :test_pid, self())
    assert :ok = AI.set_airplane_mode(false)

    server =
      start_supervised!({Bandit, plug: TitleChatServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "online-secret",
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "New Chat", model: "gpt-4.1"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
    html = render_click(view, "select_view", %{"view" => "chat"})

    assert html =~ ~s(<span class="chat-item-title">New Chat</span>)

    html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert html =~ ~s(<span class="tab-title truncate">New Chat</span>)

    _html =
      view
      |> element(".chat-input-wrapper")
      |> render_change(%{"message" => "Posts pro Monat 2026"})

    _html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    Process.sleep(350)
    html = render(view)

    assert_received {:title_chat_request, chat_request}

    refute Enum.any?(chat_request["messages"] || [], fn message ->
             String.contains?(message["content"] || "", "Generate an ultra-short title")
           end)

    assert_received {:title_chat_request, title_request}

    assert Enum.any?(title_request["messages"] || [], fn message ->
             String.contains?(message["content"] || "", "Generate an ultra-short title")
           end)

    assert AI.get_chat_conversation(conversation.id).title == "Posts 2026"
    assert html =~ ~s(<span class="tab-title truncate">Posts 2026</span>)
    assert html =~ ~r/<span class="chat-panel-title-main">\s*Posts 2026\s*<\/span>/
    assert html =~ ~s(<span class="chat-item-title">Posts 2026</span>)
    refute html =~ ~s(<span class="tab-title truncate">New Chat</span>)
    refute html =~ ~s(<span class="chat-item-title">New Chat</span>)
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
    assert html =~ ~r/chat-message-content.*data-testid="chat-inline-surface"/s

    surface_id = Regex.run(~r/id="([^"]+-surface-0)"/, html) |> Enum.at(1)

    dismissed_html =
      view
      |> element("button[phx-value-surface-id='#{surface_id}']")
      |> render_click()

    refute dismissed_html =~ ~s(data-testid="chat-inline-surface")
  end

  test "chat editor keeps every non-dismissed A2UI surface expanded" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Surface Chat", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "Show two updates",
        created_at: now
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Here are the updates.",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-card-old",
              "name" => "render_card",
              "arguments" => %{
                "title" => "Earlier Missing Data",
                "body" => "The first data request needs review."
              }
            },
            %{
              "id" => "call-card-new",
              "name" => "render_card",
              "arguments" => %{
                "title" => "Latest Missing Data",
                "body" => "The second data request needs review."
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

    assert length(:binary.matches(html, ~s(data-testid="chat-inline-surface"))) == 2
    assert length(:binary.matches(html, ~s(data-expanded="true"))) == 2
    assert length(:binary.matches(html, ~s(open=""))) == 2
    assert html =~ "Earlier Missing Data"
    assert html =~ "The first data request needs review."
    assert html =~ "Latest Missing Data"
    assert html =~ "The second data request needs review."
    assert html =~ ~r/chat-message-content.*Earlier Missing Data.*Latest Missing Data/s
  end

  test "chat editor keeps previous surfaces visible while a new update surface streams" do
    assert :ok = AI.set_airplane_mode(false)
    {:ok, _} = GatedChatServer.hold_gate()

    server =
      start_supervised!({Bandit, plug: GatedChatServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "online-secret",
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Update Surfaces", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Earlier missing data.",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-card-old",
              "name" => "render_card",
              "arguments" => %{
                "title" => "Earlier Missing Data",
                "body" => "The first data request needs review."
              }
            }
          ]),
        created_at: now
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

    _html =
      view
      |> element(".chat-input-wrapper")
      |> render_change(%{"message" => "Update missing data"})

    _html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    send_and_await(view, {
      :chat_tool_call,
      conversation.id,
      %{
        id: "call-card-new",
        name: "render_card",
        arguments: %{
          "title" => "Latest Missing Data",
          "body" => "The second data request needs review."
        }
      }
    })

    html = render(view)

    assert length(:binary.matches(html, ~s(data-testid="chat-inline-surface"))) == 2
    assert length(:binary.matches(html, ~s(data-expanded="true"))) == 2
    assert length(:binary.matches(html, ~s(open=""))) == 2
    assert html =~ "Earlier Missing Data"
    assert html =~ "The first data request needs review."
    assert html =~ "Latest Missing Data"
    assert html =~ "The second data request needs review."
    assert html =~ ~r/chat-message-content.*Earlier Missing Data.*Latest Missing Data/s

    _html =
      view
      |> element("[data-testid='chat-abort-button']")
      |> render_click()
  end

  test "chat editor hook reopens server-expanded A2UI surfaces after patches" do
    live_js = File.read!(Path.expand("../../../assets/js/hooks/chat_surface.js", __DIR__))

    chat_editor =
      File.read!(Path.expand("../../../lib/bds/desktop/shell_live/chat_editor.ex", __DIR__))

    assert chat_editor =~ "data-expanded={surface_expanded_attr(@surface)}"
    assert live_js =~ "this.syncExpandedSurfaces = () =>"
    assert live_js =~ "querySelectorAll(\".chat-inline-surface[data-expanded='true']\")"
    assert live_js =~ "surface.open = true;"
    assert live_js =~ "this.surfaceObserver = new MutationObserver"
    assert live_js =~ "this.surfaceObserver.disconnect();"
    assert live_js =~ "this.syncExpandedSurfaces();"
  end

  test "chat editor restores dismissed surfaces from persisted surface state when reopening a chat" do
    assert {:ok, conversation} = AI.start_chat(%{title: "Reopen Chat", model: "gpt-4.1"})

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :user,
        content: "Show me two cards",
        created_at: now
      })
    )

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "Here are two cards.",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-card-a",
              "name" => "render_card",
              "arguments" => %{
                "title" => "UniqueTitleAlpha",
                "body" => "First card alpha"
              }
            },
            %{
              "id" => "call-card-b",
              "name" => "render_card",
              "arguments" => %{
                "title" => "UniqueTitleBeta",
                "body" => "Second card beta"
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

    assert length(:binary.matches(html, ~s(data-testid="chat-inline-surface"))) == 2

    surface_id_a = Regex.run(~r/id="([^"]+-surface-0)"/, html) |> Enum.at(1)

    dismissed_html =
      view
      |> element("button[phx-value-surface-id='#{surface_id_a}']")
      |> render_click()

    assert length(:binary.matches(dismissed_html, ~s(data-testid="chat-inline-surface"))) == 1

    persisted = AI.get_surface_state(conversation.id)
    assert MapSet.new(persisted["dismissed_surfaces"]) == MapSet.new([surface_id_a])

    {:ok, view2, _html2} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html2 =
      render_click(view2, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    assert length(:binary.matches(html2, ~s(data-testid="chat-inline-surface"))) == 1
    assert html2 =~ "UniqueTitleBeta"
    refute html2 =~ ~r/id="#{Regex.escape(surface_id_a)}"/
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

    assert length(:binary.matches(html, ~s(<span class="chat-message-role">Assistant</span>))) ==
             1
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

    css = desktop_css_source()
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
    assert html =~ ~s(class="chat-input chat-surface-input ui-textarea")

    css = desktop_css_source()
    assert css =~ "--chat-input-line-height: 22px;"
    assert css =~ "--chat-input-min-height: 24px;"
    assert css =~ ".chat-panel .chat-input-container"
    assert css =~ "padding: 12px 16px;"
    assert css =~ "padding: 6px 8px;"
    assert css =~ ".chat-panel .chat-input-wrapper"
    assert css =~ "min-height: 40px;"
    assert css =~ "padding: 6px 8px;"
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

    live_js = File.read!(Path.expand("../../../assets/js/hooks/chat_surface.js", __DIR__))

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

    view
    |> element("[data-testid='chat-surface-action'][data-action='openPost']")
    |> render_click()

    html = render(view)
    assert html =~ ~s(data-tab-type="post")
    assert html =~ ~s(data-tab-id="#{post.id}")
  end

  test "chat editor shows in-flight stop state and can abort a running turn" do
    assert :ok = AI.set_airplane_mode(false)
    {:ok, _} = GatedChatServer.hold_gate()

    server =
      start_supervised!({Bandit, plug: GatedChatServer, port: 0, startup_log: false})

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

    _html =
      view
      |> element(".chat-input-wrapper")
      |> render_change(%{"message" => "Please wait"})

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

    GatedChatServer.release_gate()
    Process.sleep(100)
    refute render(view) =~ "Delayed response"
  end

  test "chat editor keeps the in-flight user turn visible and disables input while streaming" do
    assert :ok = AI.set_airplane_mode(false)
    {:ok, _} = GatedChatServer.hold_gate()

    server =
      start_supervised!({Bandit, plug: GatedChatServer, port: 0, startup_log: false})

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

    _html =
      view
      |> element(".chat-input-wrapper")
      |> render_change(%{"message" => "Newest question"})

    html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    {assistant_index, _length} = :binary.match(html, "Earlier answer")
    {user_index, _length} = :binary.match(html, "Newest question")

    assert assistant_index < user_index

    assert html =~
             ~r/<textarea[^>]*class="chat-input chat-surface-input ui-textarea"[^>]*disabled/

    send_and_await(view, {
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

    GatedChatServer.release_gate()
    Process.sleep(100)
    refute render(view) =~ "Delayed response"
  end

  test "chat editor does not duplicate persisted turn artifacts while the request is still active" do
    assert :ok = AI.set_airplane_mode(false)
    {:ok, _} = GatedChatServer.hold_gate()

    server =
      start_supervised!({Bandit, plug: GatedChatServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _endpoint} =
             AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "online-secret",
               model: "gpt-4.1"
             })

    assert {:ok, conversation} = AI.start_chat(%{title: "Streaming Dedupe", model: "gpt-4.1"})

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html =
      render_click(view, "pin_sidebar_item", %{
        "route" => "chat",
        "id" => conversation.id,
        "title" => conversation.title,
        "subtitle" => conversation.model || "chat"
      })

    _html =
      view
      |> element(".chat-input-wrapper")
      |> render_change(%{"message" => "Newest question"})

    html =
      view
      |> element("[data-testid='chat-send-button']")
      |> render_click()

    assert html =~ ~s(data-testid="chat-streaming-thinking")

    assert Enum.count(AI.list_chat_messages(conversation.id), fn message ->
             message.role == :user and message.content == "Newest question"
           end) == 1

    now = Persistence.now_ms()

    Repo.insert!(
      BDS.AI.ChatMessage.changeset(%BDS.AI.ChatMessage{}, %{
        conversation_id: conversation.id,
        role: :assistant,
        content: "",
        tool_calls:
          Jason.encode!([
            %{
              "id" => "call-card-new",
              "name" => "render_card",
              "arguments" => %{
                "title" => "Latest Missing Data",
                "body" => "The second data request needs review."
              }
            }
          ]),
        created_at: now + 1
      })
    )

    _ensure_sync = render(view)

    send_and_await(view, {
      :chat_tool_call,
      conversation.id,
      %{
        id: "call-card-new",
        name: "render_card",
        arguments: %{
          "title" => "Latest Missing Data",
          "body" => "The second data request needs review."
        }
      }
    })

    html = render(view)

    refute html =~ ~s(data-testid="chat-pending-user-message")
    assert length(:binary.matches(html, ~s(data-testid="chat-user-message-text"))) == 1
    assert length(:binary.matches(html, ~s(data-testid="chat-inline-surface"))) == 1
    refute html =~ ~s(data-testid="chat-streaming-message")
    assert html =~ ~s(data-testid="chat-streaming-thinking")

    _html =
      view
      |> element("[data-testid='chat-abort-button']")
      |> render_click()
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

  test "git sidebar wires branch, changes, history, and action buttons to BDS.Git", %{
    temp_dir: temp_dir
  } do
    posts_dir = Path.join(temp_dir, "posts")
    File.mkdir_p!(posts_dir)

    tracked = Path.join(posts_dir, "tracked.md")
    File.write!(tracked, "Old content\n")
    init_git_repo!(temp_dir, "seed commit")
    File.write!(tracked, "New content\n")

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='activity-button'][data-view='git']")
      |> render_click()

    assert html =~ ~s(class="git-sidebar")
    assert html =~ ~s(data-testid="git-branch")
    assert html =~ "master"
    assert html =~ ~s(data-testid="git-status-file")
    assert html =~ "posts/tracked.md"
    assert html =~ ~s(data-testid="git-commit-form")
    assert html =~ ~s(data-testid="git-action-fetch")
    assert html =~ ~s(data-testid="git-action-pull")
    assert html =~ ~s(data-testid="git-action-push")
    assert html =~ ~s(data-testid="git-action-prune-lfs")
    assert html =~ ~s(data-testid="git-history-entry")
    assert html =~ "seed commit"
  end

  test "git sidebar commit stages working tree and reloads to a clean state", %{
    project: project,
    temp_dir: temp_dir
  } do
    posts_dir = Path.join(temp_dir, "posts")
    File.mkdir_p!(posts_dir)

    File.write!(Path.join(posts_dir, "seed.md"), "Seed\n")
    init_git_repo!(temp_dir, "seed commit")
    File.write!(Path.join(posts_dir, "added.md"), "Brand new\n")

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    view
    |> element("[data-testid='activity-button'][data-view='git']")
    |> render_click()

    html = render_submit(view, "git_commit", %{"git" => %{"message" => "Add new post"}})

    refute html =~ "posts/added.md"
    assert {:ok, %{commits: commits}} = BDS.Git.history(project.id, "master")
    assert Enum.any?(commits, &(&1.subject == "Add new post"))
  end

  test "git sidebar shows the initialize control when the project is not a repo" do
    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    html =
      view
      |> element("[data-testid='activity-button'][data-view='git']")
      |> render_click()

    assert html =~ ~s(class="git-sidebar")
    assert html =~ ~s(data-testid="git-initialize")
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

    assert BDS.Repo.get(BDS.Templates.Template, template.id)
    assert html =~ "confirm-delete-modal"
    assert html =~ template.title

    html = render_click(view, "overlay_confirm", %{})

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

  # Sends a message to the LiveView and blocks until it has been processed.
  # Uses a test ping/pong to guarantee the message was handled before returning.
  defp send_and_await(view, message) do
    ref = make_ref()
    send(view.pid, message)
    send(view.pid, {:test_ping, self(), ref})

    receive do
      {:test_pong, ^ref} -> :ok
    after
      5000 -> raise "LiveView did not process messages within 5s"
    end
  end

  defp run_git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    assert status == 0, output
  end
end
