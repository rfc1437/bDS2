defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.{AI, BoundedAtoms, ImportDefinitions, Media, Posts, Scripts}
  alias BDS.CliSync.Watcher
  alias BDS.Desktop.{FolderPicker, Overlay, ShellData, UILocale}

  alias BDS.Desktop.ShellLive.{
    ChatEditor,
    ImportEditor,
    MediaEditor,
    MenuEditor,
    MiscEditor,
    ScriptEditor,
    SettingsEditor,
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
    CliSync,
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
      localize_task_status: 2,
      translate_for_socket: 2
    ]

  import TabHelpers,
    only: [
      tab_title: 2,
      tab_subtitle: 2,
      tab_id_for_route: 2,
      tab_intent: 2,
      sidebar_route_atom: 1,
      parse_integer: 1
    ]

  alias BDS.Projects
  alias BDS.Templates
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
      |> assign(:media_editor_drafts, %{})
     |> assign(:media_editor_quick_actions_open, %{})
     |> assign(:media_editor_post_pickers_open, %{})
      |> assign(:media_editor_post_picker_queries, %{})
      |> assign(:media_editor_save_states, %{})
      |> assign(:media_editor_translation_forms, %{})
     |> assign(:chat_editor_inputs, %{})
     |> assign(:chat_model_selectors_open, %{})
     |> assign(:chat_editor_requests, %{})
     |> assign(:chat_editor_request_refs, %{})
     |> assign(:chat_editor_surface_data, %{})
     |> assign(:chat_editor_surface_tabs, %{})
    |> assign(:chat_editor_dismissed_surfaces, MapSet.new())
     |> assign(:chat_editor_action_errors, %{})
     |> assign(:import_editor_analysis_states, %{})
     |> assign(:import_editor_analysis_task_refs, %{})
     |> assign(:import_editor_execution_states, %{})
     |> assign(:import_editor_execution_task_refs, %{})
     |> assign(:import_editor_sections, %{})
     |> assign(:import_editor_taxonomy_edits, %{})
     |> assign(:import_editor_model_selectors_open, %{})
     |> assign(:import_editor_selected_models, %{})
     |> assign(:misc_editor_selected_pairs, %{})
     |> assign(:misc_editor_git_selected_files, %{})
     |> assign(:metadata_diff_active_tabs, %{})
     |> assign(:metadata_diff_field_filters, %{})
     |> assign(:shell_overlay, nil)
     |> assign(:output_entries, [])
     |> reload_shell(workbench)}
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
    {:noreply, request_sidebar_delete(socket, route, id, Map.get(params, "title"))}
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

  def handle_event("change_media_editor", %{"media_editor" => params}, socket) do
    {:noreply, MediaEditor.update(socket, params, &reload_shell/2)}
  end

  def handle_event("save_media_editor", %{"id" => media_id}, socket) do
    {:noreply,
     MediaEditor.persist_socket(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("toggle_media_editor_quick_actions", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.toggle_quick_actions(socket, media_id, &reload_shell/2)}
  end

  def handle_event("replace_media_editor_file", %{"id" => media_id}, socket) do
    {:noreply,
     MediaEditor.replace_file(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("detect_media_editor_language", %{"id" => media_id}, socket) do
    {:noreply,
     MediaEditor.detect_language(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("toggle_media_post_picker", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.toggle_post_picker(socket, media_id, &reload_shell/2)}
  end

  def handle_event(
        "change_media_post_picker",
        %{"id" => media_id, "media_post_picker" => %{"query" => query}},
        socket
      ) do
    {:noreply, MediaEditor.set_post_picker_query(socket, media_id, query, &reload_shell/2)}
  end

  def handle_event("link_media_to_post", %{"id" => media_id, "post-id" => post_id}, socket) do
    {:noreply,
     MediaEditor.link_post(socket, media_id, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("unlink_media_from_post", %{"id" => media_id, "post-id" => post_id}, socket) do
    {:noreply,
     MediaEditor.unlink_post(socket, media_id, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("edit_media_translation", %{"id" => media_id, "language" => language}, socket) do
    {:noreply, MediaEditor.edit_translation(socket, media_id, language, &reload_shell/2)}
  end

  def handle_event("change_media_translation", %{"media_translation" => params}, socket) do
    case socket.assigns.current_tab do
      %{type: :media, id: media_id} ->
        {:noreply, MediaEditor.update_translation(socket, media_id, params, &reload_shell/2)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("save_media_translation", %{"id" => media_id}, socket) do
    {:noreply,
     MediaEditor.save_translation(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event(
        "refresh_media_translation",
        %{"id" => media_id, "language" => language},
        socket
      ) do
    {:noreply,
     MediaEditor.refresh_translation(
       socket,
       media_id,
       language,
       &reload_shell/2,
       &append_output_entry/5
     )}
  end

  def handle_event(
        "delete_media_translation",
        %{"id" => media_id, "language" => language},
        socket
      ) do
    {:noreply,
     MediaEditor.delete_translation(
       socket,
       media_id,
       language,
       &reload_shell/2,
       &append_output_entry/5
     )}
  end

  def handle_event("close_media_translation_editor", _params, socket) do
    case socket.assigns.current_tab do
      %{type: :media, id: media_id} ->
        {:noreply,
         socket
         |> assign(
           :media_editor_translation_forms,
           Map.delete(socket.assigns.media_editor_translation_forms, media_id)
         )
         |> reload_shell(socket.assigns.workbench)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("settings_shell_command", %{"action" => action}, socket) do
    {:noreply, apply_shell_command(socket, action)}
  end

  def handle_event("change_chat_editor_input", %{"message" => message}, socket) do
    {:noreply, ChatEditor.update_input(socket, message, &reload_shell/2)}
  end

  def handle_event("toggle_chat_model_selector", _params, socket) do
    {:noreply, ChatEditor.toggle_model_selector(socket, &reload_shell/2)}
  end

  def handle_event("select_chat_model", %{"model" => model_id}, socket) do
    {:noreply, ChatEditor.set_model(socket, model_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("send_chat_editor_message", _params, socket) do
    {:noreply, ChatEditor.send_message(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("abort_chat_editor_message", _params, socket) do
    {:noreply, ChatEditor.abort_message(socket, &reload_shell/2)}
  end

  def handle_event("open_chat_settings", _params, socket) do
    {:noreply,
     socket
     |> ChatSurface.clear_action_error()
     |> open_sidebar_item(
       %{"route" => "settings", "id" => "settings-ai", "title" => "Settings", "subtitle" => "AI"},
       :pin
     )}
  end

  def handle_event(
        "change_chat_surface_form",
        %{"surface" => %{"id" => surface_id, "fields" => fields}},
        socket
      ) do
    {:noreply, ChatEditor.update_surface_form(socket, surface_id, fields, &reload_shell/2)}
  end

  def handle_event(
        "select_chat_surface_tab",
        %{"surface-id" => surface_id, "index" => index},
        socket
      ) do
    {:noreply,
     ChatEditor.select_surface_tab(socket, surface_id, parse_integer(index), &reload_shell/2)}
  end

  def handle_event("dismiss_chat_surface", %{"surface-id" => surface_id}, socket) do
    {:noreply, ChatEditor.dismiss_surface(socket, surface_id, &reload_shell/2)}
  end

  def handle_event("chat_surface_action", params, socket) do
    {:noreply,
     ChatSurface.handle_action(socket, params, %{
       reload: &reload_shell/2,
       open_sidebar: &open_sidebar_item/3
     })}
  end

  def handle_event("change_import_editor_definition", %{"import_definition" => params}, socket) do
    {:noreply, ImportEditor.change_definition(socket, params, &reload_shell/2)}
  end

  def handle_event("select_import_uploads_folder", _params, socket) do
    {:noreply,
     ImportEditor.select_uploads_folder(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("select_import_wxr_file", _params, socket) do
    {:noreply, ImportEditor.select_and_analyze(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("execute_import_editor", _params, socket) do
    {:noreply, ImportEditor.execute_import(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_import_conflict_resolution", params, socket) do
    {:noreply, ImportEditor.change_conflict_resolution(socket, params, &reload_shell/2)}
  end

  def handle_event("start_import_taxonomy_edit", params, socket) do
    {:noreply, ImportEditor.start_taxonomy_edit(socket, params, &reload_shell/2)}
  end

  def handle_event("save_import_taxonomy_edit", params, socket) do
    {:noreply, ImportEditor.save_taxonomy_edit(socket, params, &reload_shell/2)}
  end

  def handle_event("cancel_import_taxonomy_edit", _params, socket) do
    {:noreply, ImportEditor.cancel_taxonomy_edit(socket, &reload_shell/2)}
  end

  def handle_event("clear_import_taxonomy_mapping", params, socket) do
    {:noreply, ImportEditor.clear_taxonomy_mapping(socket, params, &reload_shell/2)}
  end

  def handle_event("toggle_import_section", %{"section" => section}, socket) do
    {:noreply, ImportEditor.toggle_section(socket, section, &reload_shell/2)}
  end

  def handle_event("toggle_import_ai_model_selector", _params, socket) do
    {:noreply, ImportEditor.toggle_model_selector(socket, &reload_shell/2)}
  end

  def handle_event("select_import_ai_model", %{"model" => model_id}, socket) do
    {:noreply, ImportEditor.select_ai_model(socket, model_id, &reload_shell/2)}
  end

  def handle_event("analyze_import_taxonomy_ai", _params, socket) do
    {:noreply, ImportEditor.analyze_taxonomy_ai(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("rerun_misc_editor", _params, socket) do
    case MiscEditor.rerun(socket) do
      {:command, action} -> {:noreply, apply_shell_command(socket, action)}
      {:noop, next_socket} -> {:noreply, next_socket}
    end
  end

  def handle_event("apply_site_validation", _params, socket) do
    case MiscEditor.apply_site_validation(socket, &append_output_entry/5) do
      {:rerun, next_socket} -> {:noreply, apply_shell_command(next_socket, "validate_site")}
      {:socket, next_socket} -> {:noreply, next_socket}
    end
  end

  def handle_event("fix_translation_validation", _params, socket) do
    case MiscEditor.fix_translation_validation(socket, &append_output_entry/5) do
      {:rerun, next_socket} ->
        {:noreply, apply_shell_command(next_socket, "validate_translations")}

      {:socket, next_socket} ->
        {:noreply, next_socket}
    end
  end

  def handle_event("select_git_diff_file", %{"path" => path}, socket) do
    {:noreply, socket |> MiscEditor.select_git_diff_file(path) |> assign_misc_editor()}
  end

  def handle_event("toggle_duplicate_pair", %{"pair-id" => pair_id}, socket) do
    {:noreply, MiscEditor.toggle_duplicate(socket, pair_id, &reload_shell/2)}
  end

  def handle_event(
        "dismiss_duplicate_pair",
        %{"post-id-a" => post_id_a, "post-id-b" => post_id_b},
        socket
      ) do
    {:noreply,
     MiscEditor.dismiss_duplicate(
       socket,
       post_id_a,
       post_id_b,
       &reload_shell/2,
       &append_output_entry/5
     )}
  end

  def handle_event("dismiss_selected_duplicates", _params, socket) do
    {:noreply, MiscEditor.dismiss_selected(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("repair_metadata_diff", %{"field" => field, "direction" => direction}, socket) do
    case MiscEditor.metadata_diff_repair_request(socket, field, direction) do
      {:ok, params} ->
        {:noreply, apply_shell_command(socket, "repair_metadata_diff", params)}

      {:error, message} ->
        {:noreply,
         append_output_entry(
           socket,
           translate_for_socket(socket, "Metadata Diff"),
           message,
           nil,
           "error"
         )}
    end
  end

  def handle_event("import_metadata_diff_orphans", _params, socket) do
    case MiscEditor.metadata_diff_orphan_import_request(socket) do
      {:ok, params} ->
        {:noreply, apply_shell_command(socket, "import_metadata_diff_orphans", params)}

      {:error, message} ->
        {:noreply,
         append_output_entry(
           socket,
           translate_for_socket(socket, "Metadata Diff"),
           message,
           nil,
           "error"
         )}
    end
  end

  def handle_event("select_metadata_diff_tab", %{"tab" => tab}, socket) do
    tab_id = socket.assigns.current_tab.id

    socket =
      socket
      |> assign(
        :metadata_diff_active_tabs,
        Map.put(socket.assigns.metadata_diff_active_tabs, tab_id, tab)
      )
      |> assign(
        :metadata_diff_field_filters,
        Map.delete(socket.assigns.metadata_diff_field_filters, tab_id)
      )
      |> assign_misc_editor()

    {:noreply, socket}
  end

  def handle_event("toggle_metadata_diff_field", %{"field" => field}, socket) do
    tab_id = socket.assigns.current_tab.id
    current = Map.get(socket.assigns.metadata_diff_field_filters, tab_id)

    next_filters =
      if current == field do
        Map.delete(socket.assigns.metadata_diff_field_filters, tab_id)
      else
        Map.put(socket.assigns.metadata_diff_field_filters, tab_id, field)
      end

    {:noreply,
     socket |> assign(:metadata_diff_field_filters, next_filters) |> assign_misc_editor()}
  end

  def handle_event("open_duplicate_post", %{"id" => id, "title" => title}, socket) do
    {:noreply,
     open_sidebar_item(
       socket,
       %{"route" => "post", "id" => id, "title" => title, "subtitle" => "draft"},
       :preview
     )}
  end

  def handle_event("open_overlay", %{"kind" => kind}, socket) do
    socket =
      case socket.assigns[:current_tab] do
        %{type: :post, id: post_id} when kind in ["ai_suggestions", "language_picker"] ->
          send_update(__MODULE__.PostEditor, id: "post-editor-#{post_id}", action: :close_quick_actions)
          socket

        %{type: :media, id: media_id}
        when kind in ["ai_suggestions", "language_picker", "confirm_delete"] ->
          assign(
            socket,
            :media_editor_quick_actions_open,
            Map.put(socket.assigns.media_editor_quick_actions_open, media_id, false)
          )

        _other ->
          socket
      end

    overlay =
      with overlay_kind when not is_nil(overlay_kind) <- ShellOverlayComponents.kind(kind),
           %{type: route} <- socket.assigns[:current_tab] do
        tab = socket.assigns.current_tab
        title = tab_title(tab, socket.assigns.tab_meta)
        subtitle = tab_subtitle(tab, socket.assigns.tab_meta)

        Overlay.open(
          route,
          overlay_kind,
          ShellOverlayComponents.context(socket.assigns, title, subtitle)
        )
      end

    socket = assign(socket, :shell_overlay, overlay)

    socket =
      if kind == "ai_suggestions" and not is_nil(overlay) do
        if socket.assigns.offline_mode do
          socket
          |> assign(:shell_overlay, nil)
          |> append_output_entry(
            translated("AI Suggestions"),
            translated("Automatic AI actions stay gated by airplane mode."),
            nil,
            "info"
          )
        else
          spawn_ai_suggestions_task(socket)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :shell_overlay, nil)}
  end

  def handle_event("overlay_keydown", %{"key" => key}, socket) do
    socket =
      case {socket.assigns[:shell_overlay], key} do
        {nil, _other} ->
          socket

        {_overlay, "Escape"} ->
          assign(socket, :shell_overlay, nil)

        {%{kind: :gallery} = overlay, "ArrowLeft"} ->
          assign(socket, :shell_overlay, Overlay.lightbox_previous(overlay))

        {%{kind: :gallery} = overlay, "ArrowRight"} ->
          assign(socket, :shell_overlay, Overlay.lightbox_next(overlay))

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_toggle_ai_field", %{"key" => key}, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.toggle_ai_field(&1, key))}
  end

  def handle_event("overlay_set_search", %{"overlay" => %{"query" => query}}, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.set_search_query(&1, query))}
  end

  def handle_event("overlay_set_tab", %{"tab" => tab}, socket) do
    {:noreply,
     update_shell_overlay(socket, &Overlay.set_active_tab(&1, ShellOverlayComponents.tab(tab)))}
  end

  def handle_event("overlay_update_form", %{"overlay" => params}, socket) do
    socket =
      socket
      |> update_shell_overlay(
        &Overlay.update_form_value(&1, :external_url, Map.get(params, "url", ""))
      )
      |> update_shell_overlay(
        &Overlay.update_form_value(&1, :external_text, Map.get(params, "text", ""))
      )

    {:noreply, socket}
  end

  def handle_event("overlay_select_result", %{"id" => id}, socket) do
    overlay = socket.assigns[:shell_overlay]
    current_tab = socket.assigns[:current_tab]

    socket =
      case {overlay, current_tab} do
        {%{kind: :insert_link}, %{type: :post, id: post_id}} ->
          case Overlay.insert_link_result(overlay, id) do
            nil ->
              socket

            result ->
              send(self(), {:post_editor_insert_content, post_id, ShellOverlayComponents.markdown_link(result.title, result.canonical_url)})
              socket
          end

        {%{kind: :insert_media}, %{type: :post, id: post_id}} ->
          case Overlay.insert_media_result(overlay, id) do
            nil ->
              socket

            result ->
              syntax =
                if result.is_image do
                  "![#{result.title}](bds-media://#{result.media_id})"
                else
                  "[#{result.original_name}](bds-media://#{result.media_id})"
                end

              send(self(), {:post_editor_insert_content, post_id, syntax})
              socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_insert_external", _params, socket) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :insert_link} = overlay, %{type: :post, id: post_id}} ->
          details =
            case {overlay.external_url, String.trim(overlay.external_text || "")} do
              {"", _text} -> nil
              {url, ""} -> url
              {url, text} -> ShellOverlayComponents.markdown_link(text, url)
            end

          if details do
            send(self(), {:post_editor_insert_content, post_id, details})
          end

          socket

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_select_language", %{"code" => code}, socket) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :language_picker}, %{type: :post, id: post_id}} ->
          send(self(), {:post_editor_translate, post_id, code})
          socket

        {%{kind: :language_picker}, %{type: :media, id: media_id}} ->
          MediaEditor.translate(socket, media_id, code, &reload_shell/2, &append_output_entry/5)

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_confirm", _params, socket) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :confirm_delete, delete_action: %{source: :sidebar, route: route, id: id}}, _tab} ->
          execute_sidebar_delete(socket, route, id)

        {%{kind: :ai_suggestions} = overlay, %{type: :post, id: post_id}} ->
          send(self(), {:post_editor_apply_ai_suggestions, post_id, Overlay.selected_ai_fields(overlay)})
          socket

        {%{kind: :ai_suggestions} = overlay, %{type: :media, id: media_id}} ->
          MediaEditor.apply_ai_suggestions(
            socket,
            media_id,
            Overlay.selected_ai_fields(overlay),
            &reload_shell/2,
            &append_output_entry/5
          )

        {%{kind: :confirm_delete}, %{type: :media, id: media_id}} ->
          MediaEditor.delete_socket(socket, media_id, &reload_shell/2, &append_output_entry/5)

        {%{kind: :confirm_delete, title: title, entity_name: entity_name}, _tab} ->
          close_overlay_with_output(socket, title, entity_name)

        {%{kind: :confirm_dialog, title: title, message: message}, _tab} ->
          close_overlay_with_output(socket, title, message)

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_select_gallery_image", %{"id" => id}, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.select_gallery_image(&1, id))}
  end

  def handle_event("overlay_close_lightbox", _params, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.close_lightbox/1)}
  end

  def handle_event("overlay_lightbox_previous", _params, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.lightbox_previous/1)}
  end

  def handle_event("overlay_lightbox_next", _params, socket) do
    {:noreply, update_shell_overlay(socket, &Overlay.lightbox_next/1)}
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
      Map.has_key?(socket.assigns.import_editor_analysis_task_refs, ref) ->
        {:noreply,
         ImportEditor.finish_analysis(
           socket,
           ref,
           result,
           &reload_shell/2,
           &append_output_entry/5
         )}

      Map.has_key?(socket.assigns.import_editor_execution_task_refs, ref) ->
        {:noreply,
         ImportEditor.finish_execution(
           socket,
           ref,
           result,
           &reload_shell/2,
           &append_output_entry/5
         )}

      true ->
        {:noreply,
         ChatEditor.finish_request(socket, ref, result, &reload_shell/2, &append_output_entry/5)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    next_socket =
      cond do
        Map.has_key?(socket.assigns.import_editor_analysis_task_refs, ref) ->
          ImportEditor.handle_task_down(
            socket,
            :analysis,
            ref,
            reason,
            &reload_shell/2,
            &append_output_entry/5
          )

        Map.has_key?(socket.assigns.import_editor_execution_task_refs, ref) ->
          ImportEditor.handle_task_down(
            socket,
            :execution,
            ref,
            reason,
            &reload_shell/2,
            &append_output_entry/5
          )

        true ->
          case reason do
            :normal ->
              socket

            _other ->
              ChatEditor.finish_request(
                socket,
                ref,
                {:error, :cancelled},
                &reload_shell/2,
                &append_output_entry/5
              )
          end
      end

    {:noreply, next_socket}
  end

  def handle_info({:import_analysis_progress, definition_id, step, detail}, socket) do
    {:noreply,
     ImportEditor.note_analysis_progress(socket, definition_id, step, detail, &reload_shell/2)}
  end

  def handle_info(
        {:import_execution_progress, definition_id, phase, current, total, detail},
        socket
      ) do
    {:noreply,
     ImportEditor.note_execution_progress(
       socket,
       definition_id,
       phase,
       current,
       total,
       detail,
       &reload_shell/2
     )}
  end

  def handle_info({:chat_tool_call, conversation_id, tool_call}, socket) do
    {:noreply, ChatEditor.note_tool_call(socket, conversation_id, tool_call, &reload_shell/2)}
  end

  def handle_info({:chat_tool_result, conversation_id, name}, socket) do
    {:noreply, ChatEditor.note_tool_result(socket, conversation_id, name, &reload_shell/2)}
  end

  def handle_info({:chat_streaming_content, conversation_id, content}, socket) do
    {:noreply,
     ChatEditor.note_streaming_content(socket, conversation_id, content, &reload_shell/2)}
  end

  def handle_info({:entity_changed, payload}, socket) when is_map(payload) do
    {:noreply, CliSync.apply_entity_change(socket, payload, &reload_shell/2)}
  end

  def handle_info(:refresh_task_status, socket) do
    raw_task_status = BDS.Tasks.status_snapshot()

    case SessionUtil.next_completed_task_result(socket, raw_task_status) do
      nil ->
        task_status = localize_task_status(raw_task_status, socket.assigns.page_language)

        {:noreply,
         socket
         |> assign(:task_status, task_status)
         |> assign(:editor_meta, ShellData.editor_meta(task_status))
         |> assign(
           :status,
           ShellData.status_bar(socket.assigns.workbench, task_status, socket.assigns.dashboard,
             ui_language: socket.assigns.page_language,
             offline_mode: socket.assigns.offline_mode
           )
         )}

      task ->
        {:noreply,
         socket
         |> SessionUtil.mark_task_result_handled(task.id)
         |> apply_shell_command_result(task.result)}
    end
  end

  def handle_info({:tags_editor_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info(:tags_changed, socket) do
    {:noreply, reload_shell(socket, socket.assigns.workbench)}
  end

  def handle_info({:settings_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info(:settings_changed, socket) do
    {:noreply, reload_shell(socket, socket.assigns.workbench)}
  end

  def handle_info({:menu_editor_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info({:script_editor_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info({:template_editor_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info({:post_editor_output, title, message, level}, socket) do
    {:noreply, append_output_entry(socket, title, message, nil, level)}
  end

  def handle_info({:post_editor_dirty, post_id, dirty?}, socket) do
    workbench =
      if dirty? do
        BDS.UI.Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)
      else
        BDS.UI.Workbench.clear_dirty(socket.assigns.workbench, :post, post_id)
      end

    {:noreply, assign(socket, :workbench, workbench)}
  end

  def handle_info({:post_editor_tab_meta, post_id, title, subtitle}, socket) do
    tab_meta =
      Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: title, subtitle: subtitle})

    {:noreply, assign(socket, :tab_meta, tab_meta)}
  end

  def handle_info({:post_editor_insert_content, post_id, content}, socket) do
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :insert_content, content: content)
    {:noreply, socket}
  end

  def handle_info({:post_editor_translate, post_id, language}, socket) do
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :translate, language: language)
    {:noreply, socket}
  end

  def handle_info({:post_editor_apply_ai_suggestions, post_id, fields}, socket) do
    send_update(PostEditor, id: "post-editor-#{post_id}",
      action: :apply_ai_suggestions,
      fields: fields
    )

    {:noreply, socket}
  end

  def handle_info({:ai_suggestions_result, type, id, result}, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :ai_suggestions} = overlay ->
          current_tab = socket.assigns.current_tab

          if current_tab && current_tab.type == type && current_tab.id == id do
            suggestions =
              case type do
                :post ->
                  %{
                    "title" => result.title,
                    "excerpt" => result.excerpt,
                    "slug" => result.slug
                  }

                :media ->
                  %{
                    "title" => result.title,
                    "alt" => result.alt,
                    "caption" => result.caption
                  }
              end

            assign(socket, :shell_overlay, Overlay.set_ai_suggestions(overlay, suggestions))
          else
            socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:ai_suggestions_error, type, id, reason}, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :ai_suggestions} ->
          current_tab = socket.assigns.current_tab

          if current_tab && current_tab.type == type && current_tab.id == id do
            socket
            |> assign(:shell_overlay, nil)
            |> append_output_entry(
              translated("AI Suggestions"),
              inspect(reason),
              nil,
              "error"
            )
          else
            socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(:reload_shell, socket) do
    {:noreply, reload_shell(socket, socket.assigns.workbench)}
  end

  def handle_info({:close_tab, type, id}, socket) do
    {:noreply, reload_shell(socket, BDS.UI.Workbench.close_tab(socket.assigns.workbench, type, id))}
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
    |> assign_media_editor()
    |> assign_chat_editor()
    |> assign_import_editor()
    |> assign_misc_editor()
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

  defp assign_media_editor(socket) do
    MediaEditor.assign_socket(socket)
  end

  defp assign_chat_editor(socket) do
    ChatEditor.assign_socket(socket)
  end

  defp assign_import_editor(socket) do
    ImportEditor.assign_socket(socket)
  end

  defp assign_misc_editor(socket) do
    MiscEditor.assign_socket(socket)
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
    MediaEditor.persist_socket(socket, media_id, &reload_shell/2, &append_output_entry/5)
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

  defp spawn_ai_suggestions_task(socket) do
    current_tab = socket.assigns.current_tab

    case current_tab do
      %{type: :post, id: post_id} ->
        parent = self()

        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          case AI.analyze_post(post_id) do
            {:ok, result} ->
              send(parent, {:ai_suggestions_result, :post, post_id, result})

            {:error, reason} ->
              send(parent, {:ai_suggestions_error, :post, post_id, reason})
          end
        end)

      %{type: :media, id: media_id} ->
        parent = self()

        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          case AI.analyze_image(media_id) do
            {:ok, result} ->
              send(parent, {:ai_suggestions_result, :media, media_id, result})

            {:error, reason} ->
              send(parent, {:ai_suggestions_error, :media, media_id, reason})
          end
        end)

      _other ->
        :ok
    end

    socket
  end

  defp mac_ui? do
    case Application.get_env(:bds, :shell_platform) do
      nil -> match?({:unix, :darwin}, :os.type())
      platform -> match?({:unix, :darwin}, platform)
    end
  end

  defp update_shell_overlay(socket, updater),
    do: ChatSurface.update_shell_overlay(socket, updater)

  defp close_overlay_with_output(socket, title, details) do
    socket
    |> append_output_entry(title, translated("Command completed"), details)
    |> assign(:shell_overlay, nil)
  end

  defp request_sidebar_delete(socket, route, id, fallback_title) do
    case sidebar_delete_target(socket, route, id, fallback_title) do
      {:ok, entity_name} ->
        assign(socket, :shell_overlay, %{
          kind: :confirm_delete,
          title: sidebar_delete_title(route),
          entity_name: entity_name,
          entity_type: route,
          reference_count: 0,
          reference_list: [],
          delete_action: %{source: :sidebar, route: route, id: id}
        })

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(sidebar_delete_title(route), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp execute_sidebar_delete(socket, route, id) do
    case route do
      "post" ->
        case Posts.delete_post(id) do
          {:ok, :deleted} ->
            workbench = BDS.UI.Workbench.close_tab(socket.assigns.workbench, :post, id)

            socket
            |> assign(:shell_overlay, nil)
            |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:post, id}))
            |> reload_shell(workbench)

          {:error, reason} ->
            socket
            |> assign(:shell_overlay, nil)
            |> append_output_entry(sidebar_delete_title("post"), inspect(reason), nil, "error")
            |> reload_shell(socket.assigns.workbench)
        end

      "media" ->
        socket
        |> assign(:shell_overlay, nil)
        |> MediaEditor.delete_socket(id, &reload_shell/2, &append_output_entry/5)

      "scripts" ->
        delete_sidebar_script(socket, id)

      "templates" ->
        delete_sidebar_template(socket, id)

      "chat" ->
        delete_sidebar_chat(socket, id)

      "import" ->
        delete_sidebar_import(socket, id)

      _other ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(translated("Delete"), inspect(:unsupported_route), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp delete_sidebar_script(socket, script_id) do
    case Scripts.delete_script(script_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :scripts, script_id)

        socket
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:scripts, script_id}))
        |> reload_shell(workbench)

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(sidebar_delete_title("scripts"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp delete_sidebar_template(socket, template_id) do
    case Templates.delete_template(template_id, force: true) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :templates, template_id)

        socket
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:templates, template_id}))
        |> reload_shell(workbench)

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(sidebar_delete_title("templates"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp delete_sidebar_chat(socket, conversation_id) do
    case AI.delete_chat_conversation(conversation_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :chat, conversation_id)

        socket
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:chat, conversation_id}))
        |> reload_shell(workbench)

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(sidebar_delete_title("chat"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp delete_sidebar_import(socket, definition_id) do
    case ImportDefinitions.delete_definition(definition_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :import, definition_id)

        socket
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:import, definition_id}))
        |> clear_import_editor_state(definition_id)
        |> reload_shell(workbench)

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> append_output_entry(sidebar_delete_title("import"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp clear_import_editor_state(socket, definition_id) do
    socket
    |> assign(
      :import_editor_analysis_states,
      Map.delete(socket.assigns.import_editor_analysis_states, definition_id)
    )
    |> assign(
      :import_editor_analysis_task_refs,
      Map.delete(socket.assigns.import_editor_analysis_task_refs, definition_id)
    )
    |> assign(
      :import_editor_execution_states,
      Map.delete(socket.assigns.import_editor_execution_states, definition_id)
    )
    |> assign(
      :import_editor_execution_task_refs,
      Map.delete(socket.assigns.import_editor_execution_task_refs, definition_id)
    )
    |> assign(:import_editor_sections, Map.delete(socket.assigns.import_editor_sections, definition_id))
    |> assign(
      :import_editor_taxonomy_edits,
      Map.delete(socket.assigns.import_editor_taxonomy_edits, definition_id)
    )
    |> assign(
      :import_editor_model_selectors_open,
      Map.delete(socket.assigns.import_editor_model_selectors_open, definition_id)
    )
    |> assign(
      :import_editor_selected_models,
      Map.delete(socket.assigns.import_editor_selected_models, definition_id)
    )
  end

  defp sidebar_delete_target(socket, route, id, fallback_title) do
    active_project_id = socket.assigns.projects.active_project_id

    case route do
      "post" ->
        case Posts.get_post(id) do
          %{project_id: ^active_project_id} = post ->
            {:ok, present_title(fallback_title) || present_title(post.title) || present_title(post.slug) || id}

          _other ->
            {:error, :not_found}
        end

      "media" ->
        case Media.get_media(id) do
          %{project_id: ^active_project_id} = media ->
            {:ok,
             present_title(fallback_title) || present_title(media.title) ||
               present_title(media.original_name) || id}

          _other ->
            {:error, :not_found}
        end

      "scripts" ->
        case Scripts.get_script(id) do
          %{project_id: ^active_project_id} = script ->
            {:ok, present_title(fallback_title) || present_title(script.title) || id}

          _other ->
            {:error, :not_found}
        end

      "templates" ->
        case Templates.get_template(id) do
          %{project_id: ^active_project_id} = template ->
            {:ok, present_title(fallback_title) || present_title(template.title) || id}

          _other ->
            {:error, :not_found}
        end

      "chat" ->
        case AI.get_chat_conversation(id) do
          %{title: title} -> {:ok, present_title(fallback_title) || present_title(title) || id}
          _other -> {:error, :not_found}
        end

      "import" ->
        case ImportDefinitions.get_definition(id) do
          %{project_id: ^active_project_id} = definition ->
            {:ok, present_title(fallback_title) || present_title(definition.name) || id}

          _other ->
            {:error, :not_found}
        end

      _other ->
        {:error, :unsupported_route}
    end
  end

  defp sidebar_delete_title("chat"), do: translated("sidebar.chat.deleteConversation")
  defp sidebar_delete_title("post"), do: translated("Delete") <> " " <> translated("Post")
  defp sidebar_delete_title("media"), do: translated("Delete") <> " " <> translated("Media")
  defp sidebar_delete_title("scripts"), do: translated("Delete") <> " " <> translated("Script")
  defp sidebar_delete_title("templates"), do: translated("Delete") <> " " <> translated("Template")
  defp sidebar_delete_title("import"), do: translated("Delete") <> " " <> translated("Import")
  defp sidebar_delete_title(_route), do: translated("Delete")

  defp present_title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_title(_value), do: nil
end
