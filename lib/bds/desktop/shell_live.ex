defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.{AI, BoundedAtoms}
  alias BDS.CliSync.Watcher
  alias BDS.Desktop.{FolderPicker, ShellData, UILocale}

  alias BDS.Desktop.ShellLive.{
    Bridges,
    ChatEditor,
    ImportEditor,
    MediaEditor,
    MenuEditor,
    MiscEditor,
    OverlayManager,
    ScriptEditor,
    SettingsEditor,
    SidebarDelete,
    TagsEditor,
    TemplateEditor
  }

  alias BDS.Desktop.ShellLive.OverlayComponents, as: ShellOverlayComponents
  alias BDS.Desktop.ShellLive.PostEditor
  alias BDS.Desktop.ShellLive.SidebarComponents, as: ShellSidebarComponents
  alias BDS.Desktop.ShellLive.SidebarEvents
  alias BDS.Desktop.ShellLive.SidebarState, as: ShellSidebarState

  alias BDS.Desktop.ShellLive.{
    ChatSurface,
    Layout,
    SessionUtil,
    ShellCommandRunner,
    SidebarCreate,
    TabHelpers,
    TaskLocalization,
    TitlebarMenu
  }

  import TaskLocalization,
    only: [
      localize_task_status: 2
    ]

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

  @refresh_interval 1_500
  @output_entry_limit 20
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

  @local_menu_actions MapSet.new([
                        :toggle_sidebar,
                        :toggle_panel,
                        :toggle_assistant_sidebar,
                        :view_posts,
                        :view_media,
                        :edit_preferences,
                        :edit_menu,
                        :documentation,
                        :api_documentation,
                        :close_tab
                      ])
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
    |> MapSet.union(MapSet.new([:validate_translations, :fill_missing_translations, :find_duplicates]))
    |> MapSet.union(MapSet.new([:generate_sitemap, :validate_site, :upload_site]))
  end

  embed_templates("shell_live/*")

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      Phoenix.PubSub.subscribe(BDS.PubSub, Watcher.topic())
      :timer.send_interval(@refresh_interval, :refresh_task_status)
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
      |> assign(:shell_overlay, nil)
      |> assign(:output_entries, [])
      |> reload_shell(workbench)
      |> tap(&sync_menu_bar_locale/1)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_sidebar(socket.assigns.workbench))}
  end

  def handle_event("toggle_panel", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_panel(socket.assigns.workbench))}
  end

  def handle_event("toggle_assistant_sidebar", _params, socket) do
    {:noreply, reload_shell(socket, Workbench.toggle_assistant_sidebar(socket.assigns.workbench))}
  end

  def handle_event("select_view", %{"view" => view_id}, socket) do
    workbench =
      Workbench.click_activity(
        socket.assigns.workbench,
        BoundedAtoms.sidebar_view(view_id, :posts)
      )

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("select_panel_tab", %{"tab" => tab}, socket) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(BoundedAtoms.panel_tab(tab, :tasks))

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("open_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :preview)}
  end

  def handle_event("pin_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :pin)}
  end

  def handle_event("sync_layout", params, socket) do
    {:noreply, reload_shell(socket, Layout.sync(socket.assigns.workbench, params))}
  end

  def handle_event("resize_panel", %{"target" => target, "width" => width}, socket) do
    {:noreply, reload_shell(socket, Layout.resize(socket.assigns.workbench, target, width))}
  end

  def handle_event(event, params, socket) when event in @sidebar_filter_events do
    SidebarEvents.handle(socket, event, params, &reload_shell/2)
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
    workbench =
      Workbench.open_tab(
        socket.assigns.workbench,
        BoundedAtoms.editor_route(type, :post),
        id,
        :preview
      )

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("close_tab", %{"type" => type, "id" => id}, socket) do
    type_atom = BoundedAtoms.editor_route(type, :post)
    workbench = Workbench.close_tab(socket.assigns.workbench, type_atom, id)
    tab_meta = Map.delete(socket.assigns.tab_meta, {type_atom, id})

    {:noreply,
     socket
     |> assign(:tab_meta, tab_meta)
     |> reload_shell(workbench)}
  end

  def handle_event(
        "confirm_sidebar_delete",
        %{"route" => route, "id" => id} = params,
        socket
      ) do
    {:noreply, SidebarDelete.request_delete(socket, route, id, Map.get(params, "title"), sidebar_delete_callbacks())}
  end

  def handle_event("toggle_offline_mode", _params, socket) do
    next_mode = not socket.assigns.offline_mode

    :ok = AI.set_airplane_mode(next_mode)
    socket = assign(socket, :offline_mode, next_mode)

    {:noreply, reload_shell(socket, socket.assigns.workbench)}
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

    {:noreply, reload_shell(socket, workbench)}
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
    do: OverlayManager.handle_event("overlay_toggle_ai_field", params, socket, overlay_callbacks())

  def handle_event("overlay_set_search", params, socket),
    do: OverlayManager.handle_event("overlay_set_search", params, socket, overlay_callbacks())

  def handle_event("overlay_set_tab", params, socket),
    do: OverlayManager.handle_event("overlay_set_tab", params, socket, overlay_callbacks())

  def handle_event("overlay_update_form", params, socket),
    do: OverlayManager.handle_event("overlay_update_form", params, socket, overlay_callbacks())

  def handle_event("overlay_select_result", params, socket),
    do: OverlayManager.handle_event("overlay_select_result", params, socket, overlay_callbacks())

  def handle_event("overlay_insert_external", params, socket),
    do: OverlayManager.handle_event("overlay_insert_external", params, socket, overlay_callbacks())

  def handle_event("overlay_select_language", params, socket),
    do: OverlayManager.handle_event("overlay_select_language", params, socket, overlay_callbacks())

  def handle_event("overlay_confirm", params, socket),
    do: OverlayManager.handle_event("overlay_confirm", params, socket, overlay_callbacks())

  def handle_event("overlay_select_gallery_image", params, socket),
    do: OverlayManager.handle_event("overlay_select_gallery_image", params, socket, overlay_callbacks())

  def handle_event("overlay_close_lightbox", params, socket),
    do: OverlayManager.handle_event("overlay_close_lightbox", params, socket, overlay_callbacks())

  def handle_event("overlay_lightbox_previous", params, socket),
    do: OverlayManager.handle_event("overlay_lightbox_previous", params, socket, overlay_callbacks())

  def handle_event("overlay_lightbox_next", params, socket),
    do: OverlayManager.handle_event("overlay_lightbox_next", params, socket, overlay_callbacks())

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

  def handle_event("native_menu_action", %{"action" => action}, socket) do
    {:noreply, handle_native_menu_action(socket, action)}
  end

  def handle_event("titlebar_menu_keydown", %{"key" => key}, socket) do
    {:noreply, TitlebarMenu.handle_keydown(socket, key, &handle_native_menu_action/2)}
  end

  def handle_event("toggle_titlebar_menu", %{"group" => group}, socket) do
    {:noreply, TitlebarMenu.toggle(socket, group)}
  end

  def handle_event("hover_titlebar_menu", %{"group" => group}, socket) do
    {:noreply, TitlebarMenu.hover(socket, group)}
  end

  def handle_event("close_titlebar_menu", _params, socket) do
    {:noreply, TitlebarMenu.close(socket)}
  end

  def handle_event("titlebar_menu_action", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> TitlebarMenu.close()
     |> handle_native_menu_action(action)}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    cond do
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
        Map.has_key?(socket.assigns.chat_editor_request_refs, ref) ->
          {conversation_id, remaining_refs} = Map.pop(socket.assigns.chat_editor_request_refs, ref)

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

  def handle_info(message, socket) do
    Bridges.handle_info(message, socket, bridges_callbacks())
  end

  @impl true
  def render(assigns) do
    UILocale.put(assigns.page_language)
    index(assigns)
  end

  defp reload_shell(socket, workbench) do
    projects = ShellData.project_snapshot()
    dashboard = ShellData.dashboard(projects.active_project_id)
    git_badge_count = ShellData.git_badge_count(projects.active_project_id)
    active_view_id = Atom.to_string(workbench.active_view)
    tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})

    sidebar_data =
      ShellData.sidebar_view(
        projects.active_project_id,
        active_view_id,
        ShellSidebarState.current_filters(socket, active_view_id)
      )

    sidebar_data = ShellSidebarState.merge_ui_state(socket, active_view_id, sidebar_data)
    raw_task_status = BDS.Tasks.status_snapshot()
    activity_buttons = Workbench.activity_buttons(workbench, git_badge_count)
    page_language = socket.assigns[:page_language] || ShellData.ui_language()

    offline_mode =
      if connected?(socket) do
        Map.get(socket.assigns, :offline_mode, AI.airplane_mode?(true))
      else
        Map.get(socket.assigns, :offline_mode, true)
      end

    task_status = localize_task_status(raw_task_status, page_language)

    socket
  |> assign(:tab_meta, tab_meta)
    |> assign(:workbench, workbench)
    |> assign(:projects, projects)
    |> assign(:current_project, ShellData.current_project(projects))
    |> assign(:dashboard, dashboard)
    |> assign(:dashboard_timeline_entries, Map.get(dashboard, :timeline_entries, []))
    |> assign(:dashboard_category_counts, Map.get(dashboard, :category_counts, []))
    |> assign(:dashboard_recent_posts, Map.get(dashboard, :recent_posts, []))
    |> assign(
      :dashboard_tag_cloud_items,
      ShellData.dashboard_tag_cloud_items(Map.get(dashboard, :tag_cloud_items, []))
    )
    |> assign(:sidebar_data, sidebar_data)
    |> assign(
      :sidebar_header,
      active_sidebar_label(activity_buttons, workbench.active_view, sidebar_data)
    )
    |> assign(:assistant_cards, ShellData.assistant_cards())
    |> assign(:editor_meta, ShellData.editor_meta(task_status))
    |> assign(:task_status, task_status)
    |> assign(
      :status,
      ShellData.status_bar(workbench, task_status, dashboard,
        ui_language: page_language,
        offline_mode: offline_mode
      )
    )
    |> assign(:activity_buttons, activity_buttons)
    |> assign(:panel_tabs, ShellData.panel_tabs(workbench))
    |> assign(:supported_ui_languages, ShellData.supported_ui_languages())
    |> assign(:menu_groups, socket.assigns[:menu_groups] || TitlebarMenu.groups())
    |> assign(:titlebar_menu_item_index, socket.assigns[:titlebar_menu_item_index])
    |> assign(:current_tab, current_tab(workbench))
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, UILocale.current())

  defp encoded_shortcuts(shortcuts), do: Jason.encode!(shortcuts)

  defp encoded_workbench_session(workbench), do: Jason.encode!(Session.serialize(workbench))

  defp panel_tab_label(:tasks), do: translated("Tasks")
  defp panel_tab_label(:output), do: translated("Output")
  defp panel_tab_label(:git_log), do: translated("Git Log")
  defp panel_tab_label(tab), do: ShellData.route_label(tab)

  defp activity_label("AI Assistant"), do: "Chat"
  defp activity_label("Source Control"), do: "Git"
  defp activity_label(label), do: translated(label)

  defp active_sidebar_label(activity_buttons, active_view, sidebar_data) do
    Enum.find_value(activity_buttons, translated(Map.get(sidebar_data, :title, "")), fn button ->
      if button.id == active_view, do: activity_label(button.label), else: nil
    end)
  end

  defp sidebar_header_label(label), do: translated(label)

  defp timeline_height(entry, entries) do
    max_count =
      entries
      |> Enum.map(&(&1.count || 0))
      |> Enum.max(fn -> 1 end)

    max(4, (entry.count || 0) / max_count * 100)
  end

  defp current_tab(%{active_tab: nil}), do: nil

  defp current_tab(%{tabs: tabs, active_tab: {type, id}}) do
    Enum.find(tabs, &(&1.type == type and &1.id == id))
  end

  defp create_sidebar_item(socket, kind),
    do: SidebarCreate.create(socket, kind, sidebar_create_callbacks())

  defp sidebar_create_callbacks do
    %{
      reload: &reload_shell/2,
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

    socket
    |> assign(:tab_meta, tab_meta)
    |> reload_shell(workbench)
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

          {:error, reason} ->
            socket
            |> assign(:project_menu_open, false)
            |> append_output_entry(title, inspect(reason), nil, "error")
        end
    end
  end

  defp append_output_entry(socket, title, message, details \\ nil, level \\ "info") do
    entry = %{title: title, message: message, details: details, level: level}
    entries = [entry | socket.assigns.output_entries] |> Enum.take(@output_entry_limit)
    assign(socket, :output_entries, entries)
  end

  defp handle_native_menu_action(socket, action) do
    case BoundedAtoms.menu_action(action) do
      nil -> append_output_entry(socket, "Menu", "Unsupported shell command", action, "error")
      action_atom -> handle_menu_action(socket, action_atom)
    end
  end

  defp handle_menu_action(socket, action) when is_atom(action) do
    cond do
      MapSet.member?(@local_menu_actions, action) ->
        reload_shell(socket, MenuBar.execute(socket.assigns.workbench, action))

      MapSet.member?(@socket_menu_actions, action) ->
        handle_socket_menu_action(socket, action)

      MapSet.member?(@runtime_menu_actions, action) ->
        push_event(socket, "menu-runtime-command", %{action: Atom.to_string(action)})

      shell_command?(action) ->
        apply_shell_command(socket, Atom.to_string(action))

      true ->
        append_output_entry(socket, "Menu", "Unsupported shell command", Atom.to_string(action), "error")
    end
  end

  defp handle_socket_menu_action(socket, :new_post), do: create_sidebar_item(socket, "post")
  defp handle_socket_menu_action(socket, :import_media), do: create_sidebar_item(socket, "media")
  defp handle_socket_menu_action(socket, :save), do: save_current_tab(socket)
  defp handle_socket_menu_action(socket, :publish_selected), do: publish_current_tab(socket)

  defp handle_socket_menu_action(socket, :quit) do
    Shutdown.request_quit()
    socket
  end

  defp handle_socket_menu_action(socket, :view_on_github) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS")
    socket
  end

  defp handle_socket_menu_action(socket, :report_issue) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS/issues")
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

  defp save_current_tab(%{assigns: %{current_tab: %{type: :post, id: post_id}}} = socket) do
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :save)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :media, id: media_id}}} = socket) do
    send_update(MediaEditor, id: "media-editor-#{media_id}", action: :save)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :settings}}} = socket) do
    send_update(SettingsEditor, id: "settings-editor", action: :save_project)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :menu_editor}}} = socket) do
    send_update(MenuEditor, id: "menu-editor", action: :save)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :tags}}} = socket) do
    send_update(TagsEditor, id: "tags-editor", action: :save)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :scripts, id: script_id}}} = socket) do
    send_update(ScriptEditor, id: "script-editor-#{script_id}", action: :save)
    socket
  end

  defp save_current_tab(%{assigns: %{current_tab: %{type: :templates, id: template_id}}} = socket) do
    send_update(TemplateEditor, id: "template-editor-#{template_id}", action: :save)
    socket
  end

  defp save_current_tab(socket), do: reload_shell(socket, socket.assigns.workbench)

  defp publish_current_tab(%{assigns: %{current_tab: %{type: :post, id: post_id}}} = socket) do
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :publish)
    socket
  end

  defp publish_current_tab(socket), do: reload_shell(socket, socket.assigns.workbench)

  defp apply_shell_command(socket, action, params \\ %{}),
    do: ShellCommandRunner.execute(socket, action, params, shell_command_callbacks())

  defp apply_shell_command_result(socket, result),
    do: ShellCommandRunner.apply_result(socket, result, shell_command_callbacks())

  defp shell_command_callbacks do
    %{
      reload: &reload_shell/2,
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
      append_output: &append_output_entry/5,
      execute_sidebar_delete: fn socket, route, id ->
        SidebarDelete.execute_delete(socket, route, id, sidebar_delete_callbacks())
      end
    }

  defp sidebar_delete_callbacks,
    do: %{
      reload: &reload_shell/2,
      append_output: &append_output_entry/5
    }

  defp bridges_callbacks,
    do: %{
      reload: &reload_shell/2,
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
