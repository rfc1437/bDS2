defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.{AI, Blogmark, BoundedAtoms, Metadata}
  alias BDS.CliSync.Watcher
  alias BDS.Desktop.{FilePicker, FolderPicker, ShellData, UILocale}

  alias BDS.Desktop.ShellLive.{
    Bridges,
    ChatEditor,
    GalleryImport,
    GitHandler,
    GitRun,
    ImportEditor,
    MediaEditor,
    MenuEditor,
    MiscEditor,
    NativeMenuEvents,
    OverlayManager,
    ScriptEditor,
    SettingsEditor,
    SidebarDelete,
    TagsEditor,
    TabActions,
    TemplateEditor
  }

  alias BDS.Desktop.ShellLive.OverlayComponents, as: ShellOverlayComponents
  alias BDS.Desktop.ShellLive.PostEditor
  alias BDS.Desktop.ShellLive.SidebarComponents, as: ShellSidebarComponents
  alias BDS.Desktop.ShellLive.SidebarEvents

  alias BDS.Desktop.ShellLive.{
    ChatSurface,
    ContentState,
    Layout,
    SessionUtil,
    ShellCommandRunner,
    SidebarCreate,
    SocketState,
    TabHelpers,
    TitlebarMenu,
    UrlState
  }

  import TabHelpers,
    only: [
      tab_id_for_route: 2,
      tab_intent: 2,
      sidebar_route_atom: 1
    ]

  alias BDS.Projects
  alias BDS.UI.{Commands, MenuBar, Session, Workbench}
  alias Desktop.OS
  alias BDS.Desktop.Shutdown
  use Gettext, backend: BDS.Gettext

  @refresh_interval 1_500

  def refresh_interval, do: @refresh_interval

  @sidebar_filter_events [
    "toggle_sidebar_filters",
    "toggle_sidebar_archive",
    "toggle_sidebar_tags",
    "toggle_sidebar_categories",
    "update_sidebar_search",
    "clear_sidebar_search",
    "clear_sidebar_tags",
    "clear_sidebar_categories",
    "toggle_sidebar_tag",
    "toggle_sidebar_category",
    "select_sidebar_year",
    "select_sidebar_month",
    "clear_sidebar_month",
    "clear_sidebar_filters",
    "load_more_sidebar"
  ]

  @git_action_events ["git_fetch", "git_pull", "git_push", "git_prune_lfs"]

  @native_menu_events NativeMenuEvents.events()

  @layout_menu_actions MapSet.new([
                         :toggle_sidebar,
                         :toggle_panel,
                         :toggle_assistant_sidebar,
                         :close_tab
                       ])
  @sidebar_menu_actions MapSet.new([
                          :view_posts,
                          :view_media,
                          :edit_preferences,
                          :edit_menu,
                          :documentation,
                          :api_documentation
                        ])
  @local_menu_actions MapSet.union(@layout_menu_actions, @sidebar_menu_actions)
  @socket_menu_actions MapSet.new([
                         :new_post,
                         :import_media,
                         :save,
                         :publish_selected,
                         :quit,
                         :view_on_github,
                         :report_issue,
                         :about
                       ])
  @runtime_menu_actions MapSet.new([
                          :undo,
                          :redo,
                          :cut,
                          :copy,
                          :paste,
                          :delete,
                          :select_all,
                          :find,
                          :replace,
                          :reload,
                          :force_reload,
                          :reset_zoom,
                          :zoom_in,
                          :zoom_out,
                          :toggle_full_screen
                        ])

  def supported_menu_actions do
    @local_menu_actions
    |> MapSet.union(@socket_menu_actions)
    |> MapSet.union(@runtime_menu_actions)
    |> MapSet.union(MapSet.new([:open_in_browser, :open_data_folder]))
    |> MapSet.union(MapSet.new([:preview_post, :rebuild_database, :reindex_text]))
    |> MapSet.union(MapSet.new([:rebuild_embedding_index, :metadata_diff, :regenerate_calendar]))
    |> MapSet.union(
      MapSet.new([:validate_translations, :fill_missing_translations, :find_duplicates])
    )
    |> MapSet.union(
      MapSet.new([:generate_sitemap, :force_render_site, :validate_site, :upload_site])
    )
  end

  embed_templates("shell_live/*")

  @impl true
  def mount(params, _session, socket) do
    connected = connected?(socket)

    if connected do
      Phoenix.PubSub.subscribe(BDS.PubSub, Watcher.topic())
      attach_deep_link()
      Process.send_after(self(), :refresh_task_status, @refresh_interval)
    end

    workbench = Workbench.new()

    {:ok,
     socket
     |> assign(:page_title, ShellData.title())
     |> assign(:page_language, ShellData.ui_language())
     |> assign(:client_shortcuts, Commands.client_shortcuts())
     |> assign(:offline_mode, if(connected, do: AI.airplane_mode?(true), else: true))
     |> assign(:handled_task_results, SessionUtil.initial_handled_task_results())
     |> assign(:assistant_prompt, "")
     |> assign(:assistant_messages, [])
     |> assign(:is_mac_ui, mac_ui?())
     |> assign(:menu_groups, TitlebarMenu.groups())
     |> assign(:titlebar_menu_group, nil)
     |> assign(:titlebar_menu_item_index, nil)
     |> assign(:tab_meta, %{})
     |> assign(:project_menu_open, false)
     |> assign(:sidebar_filters_by_view, %{})
     |> assign(:sidebar_filter_panels, %{})
     |> assign(:chat_editor_request_refs, %{})
     |> assign(:file_picker_task, nil)
     |> assign(:shell_overlay, nil)
     |> assign(:git_run, nil)
     |> assign(:output_entries, [])
     |> assign(:panel_post_links, %{backlinks: [], outlinks: []})
     |> assign(:panel_git_entries, [])
     |> assign(:auto_save_timers, %{})
     |> reload_shell(workbench)
     |> UrlState.apply_params(params)
     |> tap(&sync_menu_bar_locale/1)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, refresh_layout(socket, Workbench.toggle_sidebar(socket.assigns.workbench))}
  end

  def handle_event("toggle_panel", _params, socket) do
    {:noreply, refresh_layout(socket, Workbench.toggle_panel(socket.assigns.workbench))}
  end

  def handle_event("toggle_assistant_sidebar", _params, socket) do
    {:noreply,
     refresh_layout(socket, Workbench.toggle_assistant_sidebar(socket.assigns.workbench))}
  end

  def handle_event("select_view", %{"view" => view_id}, socket) do
    workbench =
      Workbench.click_activity(
        socket.assigns.workbench,
        BoundedAtoms.sidebar_view(view_id, :posts)
      )

    {:noreply,
     socket
     |> refresh_sidebar(workbench)
     |> UrlState.push()}
  end

  def handle_event("select_panel_tab", %{"tab" => tab}, socket) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(BoundedAtoms.panel_tab(tab, :tasks))

    {:noreply, refresh_layout(socket, workbench)}
  end

  def handle_event("open_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :preview)}
  end

  def handle_event("pin_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :pin)}
  end

  def handle_event("sync_layout", params, socket) do
    {:noreply, refresh_layout(socket, Layout.sync(socket.assigns.workbench, params))}
  end

  def handle_event("resize_panel", %{"target" => target, "width" => width}, socket) do
    {:noreply, refresh_layout(socket, Layout.resize(socket.assigns.workbench, target, width))}
  end

  def handle_event(event, params, socket) when event in @sidebar_filter_events do
    SidebarEvents.handle(socket, event, params, &refresh_sidebar/2)
  end

  def handle_event(event, _params, socket) when event in @git_action_events do
    if GitRun.network_event?(event) do
      {:noreply, GitRun.start(socket, event, current_project_id(socket))}
    else
      {:noreply, GitHandler.run_action(socket, event)}
    end
  end

  def handle_event("git_run_close", _params, socket) do
    socket = GitRun.close(socket)
    {:noreply, refresh_sidebar(socket, socket.assigns.workbench)}
  end

  def handle_event("git_run_keydown", %{"key" => "Escape"}, socket) do
    socket = GitRun.close(socket)
    {:noreply, refresh_sidebar(socket, socket.assigns.workbench)}
  end

  def handle_event("git_run_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("git_commit", params, socket) do
    message = params |> get_in(["git", "message"]) |> to_string() |> String.trim()

    {:noreply, GitHandler.commit(socket, message)}
  end

  def handle_event("git_initialize", params, socket) do
    remote_url = params |> get_in(["git", "remote_url"]) |> GitHandler.normalize_remote_url()
    {:noreply, GitHandler.initialize(socket, remote_url)}
  end

  def handle_event("create_sidebar_item", %{"kind" => kind}, socket) do
    {:noreply, create_sidebar_item(socket, kind)}
  end

  def handle_event("shortcut", params, socket) do
    if Layout.ignore_shortcut?(params) do
      {:noreply, socket}
    else
      case Commands.command_for_shortcut(params) do
        nil -> {:noreply, socket}
        action -> {:noreply, handle_menu_action(socket, action)}
      end
    end
  end

  def handle_event("select_tab", %{"type" => type, "id" => id}, socket) do
    socket = TabActions.auto_save_current_post(socket)

    workbench =
      Workbench.open_tab(
        socket.assigns.workbench,
        BoundedAtoms.editor_route(type, :post),
        id,
        :preview
      )

    tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})

    {:noreply,
     socket
     |> assign(:tab_meta, tab_meta)
     |> refresh_layout(workbench)
     |> UrlState.push()}
  end

  def handle_event("close_tab", %{"type" => type, "id" => id}, socket) do
    socket = TabActions.auto_save_current_post(socket)

    type_atom = BoundedAtoms.editor_route(type, :post)
    workbench = Workbench.close_tab(socket.assigns.workbench, type_atom, id)
    tab_meta = Map.delete(socket.assigns.tab_meta, {type_atom, id})

    {:noreply,
     socket
     |> assign(:tab_meta, tab_meta)
     |> refresh_layout(workbench)
     |> UrlState.push()}
  end

  def handle_event(
        "confirm_sidebar_delete",
        %{"route" => route, "id" => id} = params,
        socket
      ) do
    {:noreply,
     SidebarDelete.request_delete(
       socket,
       route,
       id,
       Map.get(params, "title"),
       sidebar_delete_callbacks()
     )}
  end

  def handle_event("toggle_offline_mode", _params, socket) do
    next_mode = not socket.assigns.offline_mode

    :ok = AI.set_airplane_mode(next_mode)
    socket = assign(socket, :offline_mode, next_mode)

    {:noreply, refresh_layout(socket, socket.assigns.workbench)}
  end

  def handle_event("update_assistant_prompt", %{"assistant" => %{"prompt" => prompt}}, socket) do
    {:noreply, assign(socket, :assistant_prompt, prompt)}
  end

  def handle_event("submit_assistant_prompt", %{"assistant" => %{"prompt" => prompt}}, socket) do
    prompt = prompt |> to_string() |> String.trim()

    socket =
      if prompt == "" do
        assign(socket, :assistant_prompt, "")
      else
        socket
        |> assign(:assistant_prompt, "")
        |> assign(
          :assistant_messages,
          socket.assigns.assistant_messages ++ ChatSurface.assistant_turn(prompt, socket)
        )
      end

    {:noreply, socket}
  end

  def handle_event("open_tasks_panel", _params, socket) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(:tasks)

    {:noreply, refresh_layout(socket, workbench)}
  end

  def handle_event("settings_shell_command", %{"action" => action}, socket) do
    {:noreply, apply_shell_command(socket, action)}
  end

  def handle_event("open_overlay", params, socket),
    do: OverlayManager.handle_event("open_overlay", params, socket, overlay_callbacks())

  def handle_event("close_overlay", params, socket),
    do: OverlayManager.handle_event("close_overlay", params, socket, overlay_callbacks())

  def handle_event("overlay_keydown", params, socket),
    do: OverlayManager.handle_event("overlay_keydown", params, socket, overlay_callbacks())

  def handle_event("overlay_toggle_ai_field", params, socket),
    do:
      OverlayManager.handle_event("overlay_toggle_ai_field", params, socket, overlay_callbacks())

  def handle_event("overlay_set_search", params, socket),
    do: OverlayManager.handle_event("overlay_set_search", params, socket, overlay_callbacks())

  def handle_event("overlay_set_tab", params, socket),
    do: OverlayManager.handle_event("overlay_set_tab", params, socket, overlay_callbacks())

  def handle_event("overlay_update_form", params, socket),
    do: OverlayManager.handle_event("overlay_update_form", params, socket, overlay_callbacks())

  def handle_event("overlay_select_result", params, socket),
    do: OverlayManager.handle_event("overlay_select_result", params, socket, overlay_callbacks())

  def handle_event("overlay_insert_external", params, socket),
    do:
      OverlayManager.handle_event("overlay_insert_external", params, socket, overlay_callbacks())

  def handle_event("overlay_select_language", params, socket),
    do:
      OverlayManager.handle_event("overlay_select_language", params, socket, overlay_callbacks())

  def handle_event("overlay_confirm", params, socket),
    do: OverlayManager.handle_event("overlay_confirm", params, socket, overlay_callbacks())

  def handle_event("overlay_close_lightbox", params, socket),
    do: OverlayManager.handle_event("overlay_close_lightbox", params, socket, overlay_callbacks())

  def handle_event("overlay_lightbox_previous", params, socket),
    do:
      OverlayManager.handle_event(
        "overlay_lightbox_previous",
        params,
        socket,
        overlay_callbacks()
      )

  def handle_event("overlay_lightbox_next", params, socket),
    do: OverlayManager.handle_event("overlay_lightbox_next", params, socket, overlay_callbacks())

  def handle_event("add_gallery_images", %{"post-id" => post_id}, socket) do
    if socket.assigns.offline_mode and not AI.airplane_endpoint_configured?() do
      {:noreply,
       append_output_entry(
         socket,
         dgettext("ui", "Add Gallery Images"),
         dgettext("ui", "Automatic AI actions stay gated by airplane mode."),
         nil,
         "info"
       )}
    else
      project_id = socket.assigns.projects.active_project_id
      {:ok, metadata} = Metadata.get_project_metadata(project_id)
      concurrency_limit = metadata.image_import_concurrency
      language = metadata.main_language || "en"
      parent = self()

      Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
        case FilePicker.choose_files(dgettext("ui", "Add Gallery Images"),
               image_only: true,
               multiple: true
             ) do
          {:ok, paths} when is_list(paths) and paths != [] ->
            GalleryImport.start(paths, project_id, post_id, language, concurrency_limit, parent)

          :cancel ->
            send(parent, {:add_images_cancelled})

          {:error, reason} ->
            send(parent, {:add_images_error, reason})
        end
      end)

      {:noreply, assign(socket, :gallery_import_post_id, post_id)}
    end
  end

  def handle_event("toggle_project_menu", _params, socket) do
    {:noreply, assign(socket, :project_menu_open, not socket.assigns.project_menu_open)}
  end

  def handle_event("close_project_menu", _params, socket) do
    {:noreply, assign(socket, :project_menu_open, false)}
  end

  def handle_event("select_project", %{"project_id" => project_id}, socket) do
    {:noreply,
     activate_project(socket, project_id, "Select Project", fn project ->
       "Activated #{project.name}"
     end)}
  end

  def handle_event("create_project", _params, socket) do
    attrs = %{name: SessionUtil.next_project_name(socket.assigns.projects.projects)}

    socket =
      case Projects.create_project(attrs) do
        {:ok, project} ->
          activate_project(socket, project.id, "New Project", fn created ->
            "Activated #{created.name}"
          end)

        {:error, reason} ->
          append_output_entry(socket, "New Project", inspect(reason), nil, "error")
      end

    {:noreply, socket}
  end

  def handle_event("import_project", _params, socket) do
    socket =
      case FolderPicker.choose_directory("Open Existing Blog") do
        {:ok, path} ->
          name =
            path
            |> Path.basename()
            |> String.trim()
            |> case do
              "" -> "Imported Blog"
              value -> value
            end

          case Projects.create_project(%{name: name, data_path: path}) do
            {:ok, project} ->
              activate_project(socket, project.id, "Open Existing Blog", fn imported ->
                "Activated #{imported.name}"
              end)

            {:error, reason} ->
              append_output_entry(socket, "Open Existing Blog", inspect(reason), nil, "error")
          end

        :cancel ->
          assign(socket, :project_menu_open, false)

        {:error, %{message: message}} ->
          append_output_entry(socket, "Open Existing Blog", message, nil, "error")
      end

    {:noreply, socket}
  end

  def handle_event("change_ui_language", %{"ui_language" => language}, socket) do
    {:noreply, set_page_language(socket, language)}
  end

  def handle_event("sync_ui_language", %{"language" => language}, socket) do
    {:noreply, set_page_language(socket, language)}
  end

  def handle_event("restore_workbench_session", %{"session" => session_payload}, socket)
      when is_map(session_payload) do
    {:noreply, reload_shell(socket, SessionUtil.restore_workbench_session(session_payload))}
  end

  def handle_event(event, params, socket) when event in @native_menu_events do
    NativeMenuEvents.handle(event, params, socket, &handle_native_menu_action/2)
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    cond do
      socket.assigns.file_picker_task == ref ->
        {:noreply,
         socket
         |> assign(:file_picker_task, nil)
         |> handle_file_picker_result(result)}

      Map.has_key?(socket.assigns.chat_editor_request_refs, ref) ->
        {conversation_id, remaining_refs} = Map.pop(socket.assigns.chat_editor_request_refs, ref)

        send_update(ChatEditor,
          id: "chat-editor-#{conversation_id}",
          action: :finish_request,
          result: result
        )

        {:noreply, assign(socket, :chat_editor_request_refs, remaining_refs)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    next_socket =
      cond do
        socket.assigns.file_picker_task == ref ->
          if reason == :normal do
            assign(socket, :file_picker_task, nil)
          else
            socket
            |> assign(:file_picker_task, nil)
            |> append_output_entry(
              dgettext("ui", "Import media"),
              inspect(reason),
              nil,
              "error"
            )
            |> refresh_content(socket.assigns.workbench)
          end

        Map.has_key?(socket.assigns.chat_editor_request_refs, ref) ->
          {conversation_id, remaining_refs} =
            Map.pop(socket.assigns.chat_editor_request_refs, ref)

          if reason == :normal do
            assign(socket, :chat_editor_request_refs, remaining_refs)
          else
            send_update(ChatEditor,
              id: "chat-editor-#{conversation_id}",
              action: :finish_request,
              result: {:error, :cancelled}
            )

            assign(socket, :chat_editor_request_refs, remaining_refs)
          end

        true ->
          socket
      end

    {:noreply, next_socket}
  end

  def handle_info({:ai_suggestions_result, type, id, result}, socket) do
    OverlayManager.handle_info({:ai_suggestions_result, type, id, result}, socket)
  end

  def handle_info({:ai_suggestions_error, type, id, reason}, socket) do
    OverlayManager.handle_info({:ai_suggestions_error, type, id, reason}, socket)
  end

  def handle_info({:add_image_processed, title}, socket) do
    {:noreply,
     append_output_entry(
       socket,
       dgettext("ui", "Add Gallery Images"),
       dgettext("ui", "Added %{title}", title: title),
       nil,
       "info"
     )}
  end

  def handle_info({:add_images_complete, count}, socket) do
    post_id = socket.assigns[:gallery_import_post_id]

    socket =
      if is_binary(post_id) do
        send_update(PostEditor,
          id: "post-editor-#{post_id}",
          action: :insert_content,
          content: "\n[[gallery]]\n"
        )

        send_update(PostEditor,
          id: "post-editor-#{post_id}",
          action: :refresh
        )

        socket
        |> assign(:gallery_import_post_id, nil)
      else
        socket
      end

    {:noreply,
     socket
     |> append_output_entry(
       dgettext("ui", "Add Gallery Images"),
       dgettext("ui", "Added %{count} images to post", count: count),
       nil,
       "info"
     )}
  end

  def handle_info({:add_images_error, reason}, socket) do
    {:noreply,
     append_output_entry(
       socket,
       dgettext("ui", "Add Gallery Images"),
       inspect(reason),
       nil,
       "error"
     )}
  end

  def handle_info({:add_image_error, path, reason}, socket) do
    {:noreply,
     append_output_entry(
       socket,
       dgettext("ui", "Add Gallery Images"),
       dgettext("ui", "Failed to process %{path}: %{reason}",
         path: Path.basename(path),
         reason: inspect(reason)
       ),
       nil,
       "error"
     )}
  end

  def handle_info({:add_images_cancelled}, socket) do
    {:noreply, socket}
  end

  def handle_info({:test_ping, caller, ref}, socket) do
    send(caller, {:test_pong, ref})
    {:noreply, socket}
  end

  def handle_info({:blogmark_deep_link, url}, socket) when is_binary(url) do
    {:noreply, handle_blogmark_deep_link(socket, url)}
  end

  def handle_info({:git_output, ref, stream, chunk}, socket) do
    {:noreply, GitRun.append(socket, ref, stream, chunk)}
  end

  def handle_info({:git_done, ref, status}, socket) do
    socket = GitRun.done(socket, ref, status)
    {:noreply, refresh_sidebar(socket, socket.assigns.workbench)}
  end

  def handle_info({:shell_alert, title, message}, socket) do
    overlay = %{kind: :alert, title: title, message: message, tone: "error"}
    {:noreply, assign(socket, :shell_overlay, overlay)}
  end

  def handle_info(message, socket) do
    Bridges.handle_info(message, socket, bridges_callbacks())
  end

  @impl true
  def render(assigns) do
    UILocale.put(assigns.page_language)
    index(assigns)
  end

  # Dark-themed toast classes for LiveToast (its default is bg-white/text-black).
  # Mirrors the library's structural classes but uses the app's dark palette.
  @doc false
  @spec toast_class_fn(map()) :: [String.t() | false]
  def toast_class_fn(assigns) do
    [
      "group/toast z-100 pointer-events-auto relative w-full items-center justify-between origin-center overflow-hidden rounded-lg p-4 shadow-lg border col-start-1 col-end-1 row-start-1 row-end-2",
      "bg-[#2d2d2d] text-[#f0f0f0] border-[#3c3c3c]",
      "[@media(scripting:enabled)]:opacity-0 [@media(scripting:enabled){[data-phx-main]_&}]:opacity-100",
      if(assigns[:rest][:hidden] == true, do: "hidden", else: "flex"),
      assigns[:kind] == :error && "!bg-[#3a2020] !text-red-300 !border-[#5a2a2a]"
    ]
  end

  defp refresh_layout(socket, workbench), do: SocketState.refresh_layout(socket, workbench)

  defp refresh_sidebar(socket, workbench), do: SocketState.refresh_sidebar(socket, workbench)

  defp refresh_content(socket, workbench), do: ContentState.refresh_content(socket, workbench)

  defp reload_shell(socket, workbench), do: ContentState.reload_shell(socket, workbench)

  defp encoded_shortcuts(shortcuts), do: Jason.encode!(shortcuts)

  defp encoded_workbench_session(workbench), do: Jason.encode!(Session.serialize(workbench))

  defp panel_tab_label(:tasks), do: dgettext("ui", "Tasks")
  defp panel_tab_label(:output), do: dgettext("ui", "Output")
  defp panel_tab_label(:git_log), do: dgettext("ui", "Git Log")
  defp panel_tab_label(tab), do: ShellData.route_label(tab)

  defp activity_label("AI Assistant"), do: dgettext("ui", "Chat")
  defp activity_label("Source Control"), do: dgettext("ui", "Git")
  defp activity_label(label), do: label

  defp sidebar_header_label(label), do: label

  defp timeline_height(entry, entries) do
    max_count =
      entries
      |> Enum.map(&(&1.count || 0))
      |> Enum.max(fn -> 1 end)

    max(4, (entry.count || 0) / max_count * 100)
  end

  defp create_sidebar_item(socket, kind),
    do: SidebarCreate.create(socket, kind, sidebar_create_callbacks())

  # Receive a bds2://new-post blogmark deep link: run the transform pipeline,
  # create a draft post, open it in the editor, and surface transform toasts.
  defp handle_blogmark_deep_link(socket, url) do
    title = dgettext("ui", "Blogmark")
    link_project_id = Blogmark.deep_link_project_id(url)
    active = current_project_id(socket)

    cond do
      # A specific project was requested but does not exist in this install
      # (e.g. a bookmarklet copied from another instance). Never guess another
      # project — tell the user, import nothing.
      is_binary(link_project_id) and Projects.get_project(link_project_id) == nil ->
        append_output_entry(
          socket,
          title,
          dgettext("ui", "The project this blogmark targets does not exist here."),
          url,
          "error"
        )

      # A specific, existing project that isn't active: switch to it first so
      # the new post is shown in context, then import there.
      is_binary(link_project_id) and link_project_id != active ->
        case Projects.set_active_project(link_project_id) do
          {:ok, _project} ->
            socket
            |> assign(:project_menu_open, false)
            |> assign(:sidebar_filters_by_view, %{})
            |> reload_shell(Workbench.new())
            |> UrlState.push()
            |> import_blogmark(link_project_id, url, title)

          {:error, reason} ->
            append_output_entry(socket, title, inspect(reason), url, "error")
        end

      # The link names the already-active project, or no project_id was given
      # and a project is active: import into the active project.
      is_binary(active) ->
        import_blogmark(socket, active, url, title)

      # No project_id and nothing active.
      true ->
        append_output_entry(
          socket,
          title,
          dgettext("ui", "Open a project before importing a blogmark."),
          url,
          "warning"
        )
    end
  end

  defp import_blogmark(socket, project_id, url, title) do
    case Blogmark.receive_deep_link(project_id, url) do
      {:ok, %{post: post, toasts: toasts, errors: errors}} ->
        socket
        |> reload_shell(socket.assigns.workbench)
        |> open_sidebar_item(
          %{
            "route" => "post",
            "id" => post.id,
            "title" => post.title,
            "subtitle" => post.slug
          },
          :pin
        )
        |> append_blogmark_toasts(title, toasts)
        |> append_blogmark_errors(title, errors)

      {:error, reason} ->
        append_output_entry(socket, title, inspect(reason), url, "error")
    end
  end

  defp append_blogmark_toasts(socket, title, toasts) do
    Enum.reduce(toasts, socket, fn message, acc ->
      append_output_entry(acc, title, message, nil, "info")
    end)
  end

  defp append_blogmark_errors(socket, title, errors) do
    Enum.reduce(errors, socket, fn %{slug: slug, reason: reason}, acc ->
      append_output_entry(acc, title, inspect(reason), slug, "error")
    end)
  end

  defp handle_file_picker_result(socket, {:ok, _media}),
    do: refresh_content(socket, socket.assigns.workbench)

  defp handle_file_picker_result(socket, :cancel), do: socket

  defp handle_file_picker_result(socket, {:error, %{message: message}}),
    do:
      socket
      |> append_output_entry(dgettext("ui", "Import media"), message, nil, "error")
      |> refresh_content(socket.assigns.workbench)

  defp handle_file_picker_result(socket, {:error, reason}),
    do:
      socket
      |> append_output_entry(dgettext("ui", "Import media"), inspect(reason), nil, "error")
      |> refresh_content(socket.assigns.workbench)

  defp sidebar_create_callbacks do
    %{
      reload: &reload_shell/2,
      refresh_content: &refresh_content/2,
      open_sidebar: &open_sidebar_item/3,
      append_output: &append_output_entry/5
    }
  end

  defp open_sidebar_item(socket, params, intent) do
    route_atom = sidebar_route_atom(Map.fetch!(params, "route"))
    tab_id = tab_id_for_route(route_atom, Map.fetch!(params, "id"))

    workbench =
      Workbench.open_tab(
        socket.assigns.workbench,
        route_atom,
        tab_id,
        tab_intent(route_atom, intent)
      )

    tab_meta =
      Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{
        sidebar_item_id: Map.get(params, "id"),
        title: Map.get(params, "title", ""),
        subtitle: Map.get(params, "subtitle", "")
      })

    tab_meta = TabHelpers.sync_tab_meta(workbench, tab_meta)

    socket
    |> assign(:tab_meta, tab_meta)
    |> refresh_layout(workbench)
    |> UrlState.push()
  end

  defp current_project_id(socket), do: (socket.assigns[:projects] || %{})[:active_project_id]

  # Register this shell with the deep-link router and drain any links queued
  # before connect (cold start). The router is absent in headless/test runs.
  defp attach_deep_link do
    if Process.whereis(BDS.Desktop.DeepLink) do
      BDS.Desktop.DeepLink.attach(self())
    end
  end

  defp sidebar_create_action(view), do: SidebarCreate.action(view)

  defp set_page_language(socket, language) do
    codes =
      Enum.map(
        socket.assigns[:supported_ui_languages] || ShellData.supported_ui_languages(),
        & &1.code
      )

    normalized =
      language
      |> to_string()
      |> String.trim()
      |> case do
        value -> if(value in codes, do: value, else: socket.assigns.page_language)
      end

    if normalized == socket.assigns.page_language do
      socket
    else
      UILocale.put(normalized)

      socket
      |> assign(:page_language, normalized)
      |> reload_shell(socket.assigns.workbench)
      |> tap(&sync_menu_bar_locale/1)
    end
  end

  defp activate_project(socket, project_id, title, message_fun) do
    cond do
      project_id == socket.assigns.projects.active_project_id ->
        assign(socket, :project_menu_open, false)

      true ->
        case Projects.set_active_project(project_id) do
          {:ok, project} ->
            socket
            |> assign(:project_menu_open, false)
            |> assign(:sidebar_filters_by_view, %{})
            |> append_output_entry(title, message_fun.(project))
            |> reload_shell(Workbench.new())
            |> UrlState.push()

          {:error, reason} ->
            socket
            |> assign(:project_menu_open, false)
            |> append_output_entry(title, inspect(reason), nil, "error")
        end
    end
  end

  defp append_output_entry(socket, title, message, details \\ nil, level \\ "info"),
    do: SocketState.append_output_entry(socket, title, message, details, level)

  defp handle_native_menu_action(socket, action) do
    case BoundedAtoms.menu_action(action) do
      nil -> append_output_entry(socket, "Menu", "Unsupported shell command", action, "error")
      action_atom -> handle_menu_action(socket, action_atom)
    end
  end

  defp handle_menu_action(socket, action) when is_atom(action) do
    cond do
      MapSet.member?(@layout_menu_actions, action) ->
        refresh_layout(socket, MenuBar.execute(socket.assigns.workbench, action))

      MapSet.member?(@sidebar_menu_actions, action) ->
        workbench = MenuBar.execute(socket.assigns.workbench, action)
        tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})

        socket
        |> assign(:tab_meta, tab_meta)
        |> refresh_sidebar(workbench)
        |> UrlState.push()

      MapSet.member?(@socket_menu_actions, action) ->
        handle_socket_menu_action(socket, action)

      MapSet.member?(@runtime_menu_actions, action) ->
        push_event(socket, "menu-runtime-command", %{action: Atom.to_string(action)})

      shell_command?(action) ->
        apply_shell_command(socket, Atom.to_string(action))

      true ->
        append_output_entry(
          socket,
          "Menu",
          "Unsupported shell command",
          Atom.to_string(action),
          "error"
        )
    end
  end

  defp handle_socket_menu_action(socket, :new_post), do: create_sidebar_item(socket, "post")
  defp handle_socket_menu_action(socket, :import_media), do: create_sidebar_item(socket, "media")

  defp handle_socket_menu_action(socket, :save), do: TabActions.save_current_tab(socket)

  defp handle_socket_menu_action(socket, :publish_selected),
    do: TabActions.publish_current_tab(socket)

  defp handle_socket_menu_action(socket, :quit) do
    Shutdown.request_quit()
    socket
  end

  defp handle_socket_menu_action(socket, :view_on_github) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS2")
    socket
  end

  defp handle_socket_menu_action(socket, :report_issue) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS2/issues")
    socket
  end

  defp handle_socket_menu_action(socket, :about) do
    append_output_entry(
      socket,
      "About",
      "Blogging Desktop Server",
      "Version #{Application.spec(:bds, :vsn) |> to_string()}",
      "info"
    )
  end

  defp shell_command?(action), do: not is_nil(shell_command_atom(action))

  defp apply_shell_command(socket, action, params \\ %{}),
    do: ShellCommandRunner.execute(socket, action, params, shell_command_callbacks())

  defp apply_shell_command_result(socket, result),
    do: ShellCommandRunner.apply_result(socket, result, shell_command_callbacks())

  defp shell_command_callbacks do
    %{
      reload: &reload_shell/2,
      refresh_content: &refresh_content/2,
      append_output: &append_output_entry/5
    }
  end

  defp shell_command_atom(action), do: ShellCommandRunner.shell_command_atom(action)

  defp mac_ui? do
    case Application.get_env(:bds, :shell_platform) do
      nil -> match?({:unix, :darwin}, :os.type())
      platform -> match?({:unix, :darwin}, platform)
    end
  end

  defp overlay_callbacks,
    do: %{
      reload: &reload_shell/2,
      refresh_content: &refresh_content/2,
      append_output: &append_output_entry/5,
      execute_sidebar_delete: fn socket, route, id ->
        SidebarDelete.execute_delete(socket, route, id, sidebar_delete_callbacks())
      end
    }

  defp sidebar_delete_callbacks,
    do: %{
      reload: &reload_shell/2,
      refresh_content: &refresh_content/2,
      append_output: &append_output_entry/5
    }

  defp bridges_callbacks,
    do: %{
      reload: &reload_shell/2,
      refresh_layout: &refresh_layout/2,
      refresh_sidebar: &refresh_sidebar/2,
      refresh_content: &refresh_content/2,
      append_output: &append_output_entry/5,
      open_sidebar: &open_sidebar_item/3,
      apply_shell_command: &apply_shell_command/3,
      apply_shell_command_result: &apply_shell_command_result/2
    }

  defp sync_menu_bar_locale(socket) do
    locale = socket.assigns.page_language

    case Process.whereis(BDS.Desktop.MenuBar) do
      nil -> :ok
      pid -> send(pid, {:set_ui_locale, locale})
    end
  end
end
