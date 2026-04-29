defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.AI
  alias BDS.Desktop.{FilePicker, FolderPicker, Overlay, ShellCommands, ShellData}
  alias BDS.Desktop.ShellLive.{ChatEditor, CodeEntityEditor, MediaEditor, MenuEditor, MiscEditor, SettingsEditor, TagsEditor}
  alias BDS.Desktop.ShellLive.OverlayComponents, as: ShellOverlayComponents
  alias BDS.Desktop.ShellLive.PostEditor
  alias BDS.Desktop.ShellLive.SidebarComponents, as: ShellSidebarComponents
  alias BDS.Desktop.ShellLive.SidebarState, as: ShellSidebarState
  alias BDS.Desktop.MenuBar, as: DesktopMenuBar
  alias BDS.Git
  alias BDS.ImportDefinitions
  alias BDS.Media.Media
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts
  alias BDS.Templates
  alias BDS.UI.{Commands, MenuBar, Registry, Session, Workbench}

  @refresh_interval 1_500
  @output_entry_limit 20
  @default_new_project_name "New Blog"
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

  embed_templates "shell_live/*"

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      :timer.send_interval(@refresh_interval, :refresh_task_status)
    end

    workbench = Workbench.new()

    {:ok,
     socket
     |> assign(:page_title, ShellData.title())
     |> assign(:page_language, ShellData.ui_language())
      |> assign(:client_shortcuts, Commands.client_shortcuts())
    |> assign(:offline_mode, if(connected, do: AI.airplane_mode?(true), else: true))
      |> assign(:handled_task_results, initial_handled_task_results())
      |> assign(:assistant_prompt, "")
      |> assign(:assistant_messages, [])
    |> assign(:is_mac_ui, mac_ui?())
    |> assign(:menu_groups, titlebar_menu_groups())
    |> assign(:titlebar_menu_group, nil)
      |> assign(:titlebar_menu_item_index, nil)
     |> assign(:tab_meta, %{})
      |> assign(:project_menu_open, false)
      |> assign(:sidebar_filters_by_view, %{})
      |> assign(:sidebar_filter_panels, %{})
        |> assign(:post_editor_drafts, %{})
        |> assign(:post_editor_active_languages, %{})
        |> assign(:post_editor_tag_queries, %{})
        |> assign(:post_editor_category_queries, %{})
        |> assign(:post_editor_quick_actions_open, %{})
        |> assign(:post_editor_modes, %{})
        |> assign(:post_editor_expanded, %{})
        |> assign(:post_editor_save_states, %{})
        |> assign(:media_editor_drafts, %{})
        |> assign(:media_editor_quick_actions_open, %{})
        |> assign(:media_editor_post_pickers_open, %{})
        |> assign(:media_editor_post_picker_queries, %{})
        |> assign(:media_editor_save_states, %{})
        |> assign(:media_editor_translation_forms, %{})
        |> assign(:settings_editor_search, "")
        |> assign(:settings_editor_project_draft, %{})
          |> assign(:settings_editor_endpoint_models, %{})
        |> assign(:settings_editor_publishing_draft, %{})
        |> assign(:settings_editor_new_category, "")
        |> assign(:style_editor_theme, nil)
        |> assign(:style_editor_preview_mode, "auto")
        |> assign(:tags_editor_selected, [])
        |> assign(:tags_editor_new_tag, %{"name" => "", "color" => ""})
        |> assign(:tags_editor_edit_draft, %{})
        |> assign(:tags_editor_merge_target, "")
        |> assign(:script_editor_drafts, %{})
        |> assign(:template_editor_drafts, %{})
        |> assign(:chat_editor_inputs, %{})
        |> assign(:chat_model_selectors_open, %{})
        |> assign(:chat_editor_requests, %{})
        |> assign(:chat_editor_request_refs, %{})
        |> assign(:chat_editor_surface_data, %{})
        |> assign(:chat_editor_surface_tabs, %{})
        |> assign(:chat_editor_action_errors, %{})
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
    workbench = Workbench.click_activity(socket.assigns.workbench, String.to_existing_atom(view_id))
    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("select_panel_tab", %{"tab" => tab}, socket) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(String.to_existing_atom(tab))

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("open_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :preview)}
  end

  def handle_event("pin_sidebar_item", %{"route" => _route, "id" => _id} = params, socket) do
    {:noreply, open_sidebar_item(socket, params, :pin)}
  end

  def handle_event("sync_layout", params, socket) do
    {:noreply, reload_shell(socket, sync_layout(socket.assigns.workbench, params))}
  end

  def handle_event("resize_panel", %{"target" => target, "width" => width}, socket) do
    {:noreply, reload_shell(socket, resize_panel(socket.assigns.workbench, target, width))}
  end

  def handle_event("toggle_sidebar_filters", _params, socket) do
    socket =
      ShellSidebarState.put_filter_panel_state(socket, fn state ->
        if state.visible do
          %{state | visible: false}
        else
          %{visible: true, archive_collapsed: true, tags_collapsed: true, categories_collapsed: true, expanded_year: nil}
        end
      end)

    {:noreply,
     socket
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_archive", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filter_panel_state(fn state -> %{state | archive_collapsed: not state.archive_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_tags", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filter_panel_state(fn state -> %{state | tags_collapsed: not state.tags_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_categories", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filter_panel_state(fn state -> %{state | categories_collapsed: not state.categories_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("update_sidebar_search", %{"sidebar_filters" => params}, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :search, ShellSidebarState.normalize_filter_string(Map.get(params, "search"))) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_search", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :search, nil) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_tags", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :tags, []) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_categories", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :categories, []) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_tag", %{"tag" => tag}, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filters(fn filters -> ShellSidebarState.toggle_filter_value(filters, :tags, tag) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_category", %{"category" => category}, socket) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters -> ShellSidebarState.toggle_filter_value(filters, :categories, category) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("select_sidebar_year", %{"year" => year}, socket) do
    parsed_year = ShellSidebarState.parse_optional_integer(year)

    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state |
         archive_collapsed: false,
         expanded_year: if(state.expanded_year == parsed_year, do: nil, else: parsed_year)
       }
     end)
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:year, parsed_year)
       |> Map.put(:month, nil)
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("select_sidebar_month", %{"year" => year, "month" => month}, socket) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state | archive_collapsed: false, expanded_year: ShellSidebarState.parse_optional_integer(year)}
     end)
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:year, ShellSidebarState.parse_optional_integer(year))
       |> Map.put(:month, ShellSidebarState.parse_optional_integer(month))
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_month", _params, socket) do
    {:noreply,
     socket
      |> ShellSidebarState.put_filter_panel_state(fn state -> %{state | archive_collapsed: false} end)
      |> ShellSidebarState.put_filters(fn filters -> filters |> Map.put(:year, nil) |> Map.put(:month, nil) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_filters", _params, socket) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:search, nil)
       |> Map.put(:year, nil)
       |> Map.put(:month, nil)
       |> Map.put(:tags, [])
       |> Map.put(:categories, [])
       |> Map.put(:display_limit, ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data))
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("load_more_sidebar", _params, socket) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       Map.update(filters, :display_limit, ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data), &(&1 + ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data)))
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("create_sidebar_item", %{"kind" => kind}, socket) do
    {:noreply, create_sidebar_item(socket, kind)}
  end

  def handle_event("shortcut", params, socket) do
    if ignore_shortcut?(params) do
      {:noreply, socket}
    else
      {:noreply, reload_shell(socket, Commands.handle_shortcut(socket.assigns.workbench, params))}
    end
  end

  def handle_event("select_tab", %{"type" => type, "id" => id}, socket) do
    workbench =
      Workbench.open_tab(socket.assigns.workbench, String.to_existing_atom(type), id, :preview)

    {:noreply, reload_shell(socket, workbench)}
  end

  def handle_event("close_tab", %{"type" => type, "id" => id}, socket) do
    type_atom = String.to_existing_atom(type)
    workbench = Workbench.close_tab(socket.assigns.workbench, type_atom, id)
    tab_meta = Map.delete(socket.assigns.tab_meta, {type_atom, id})

    {:noreply,
     socket
     |> assign(:tab_meta, tab_meta)
     |> reload_shell(workbench)}
  end

  def handle_event("delete_sidebar_template", %{"id" => template_id}, socket) do
    case Repo.get(Templates.Template, template_id) do
      %Templates.Template{project_id: project_id} when project_id == socket.assigns.projects.active_project_id ->
        case Templates.delete_template(template_id) do
          {:ok, :deleted} ->
            workbench = Workbench.close_tab(socket.assigns.workbench, :templates, template_id)
            tab_meta = Map.delete(socket.assigns.tab_meta, {:templates, template_id})

            {:noreply,
             socket
             |> assign(:tab_meta, tab_meta)
             |> reload_shell(workbench)}

          {:error, reason} ->
            {:noreply,
             socket
             |> append_output_entry(translated("Delete") <> " " <> translated("Template"), inspect(reason), nil, "error")
             |> reload_shell(socket.assigns.workbench)}
        end

      _other ->
        {:noreply,
         socket
         |> append_output_entry(translated("Delete") <> " " <> translated("Template"), inspect(:not_found), nil, "error")
         |> reload_shell(socket.assigns.workbench)}
    end
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
        |> assign(:assistant_messages, socket.assigns.assistant_messages ++ assistant_turn(prompt, socket))
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

  def handle_event("change_post_editor", %{"post_editor" => params}, socket) do
    {:noreply, PostEditor.update(socket, params, &reload_shell/2)}
  end

  def handle_event("save_post_editor", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.persist_socket(socket, post_id, :save, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("publish_post_editor", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.persist_socket(socket, post_id, :publish, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("discard_post_editor", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.discard_socket(socket, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("delete_post_editor", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.delete_socket(socket, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("set_post_editor_mode", %{"id" => post_id, "mode" => mode}, socket) do
    {:noreply, PostEditor.set_mode(socket, post_id, mode, &reload_shell/2)}
  end

  def handle_event("toggle_post_metadata", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.toggle_section(socket, post_id, :metadata, &reload_shell/2)}
  end

  def handle_event("toggle_post_excerpt", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.toggle_section(socket, post_id, :excerpt, &reload_shell/2)}
  end

  def handle_event("select_post_editor_language", %{"id" => post_id, "language" => language}, socket) do
    {:noreply, PostEditor.select_language(socket, post_id, language, &reload_shell/2)}
  end

  def handle_event("toggle_post_editor_quick_actions", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.toggle_quick_actions(socket, post_id, &reload_shell/2)}
  end

  def handle_event("detect_post_editor_language", %{"id" => post_id}, socket) do
    {:noreply, PostEditor.detect_language(socket, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("add_post_editor_tag", %{"id" => post_id, "tag" => tag}, socket) do
    {:noreply, PostEditor.add_list_value(socket, post_id, :tags, tag, &reload_shell/2)}
  end

  def handle_event("remove_post_editor_tag", %{"id" => post_id, "tag" => tag}, socket) do
    {:noreply, PostEditor.remove_list_value(socket, post_id, :tags, tag, &reload_shell/2)}
  end

  def handle_event("add_post_editor_category", %{"id" => post_id, "category" => category}, socket) do
    {:noreply, PostEditor.add_list_value(socket, post_id, :categories, category, &reload_shell/2)}
  end

  def handle_event("remove_post_editor_category", %{"id" => post_id, "category" => category}, socket) do
    {:noreply, PostEditor.remove_list_value(socket, post_id, :categories, category, &reload_shell/2)}
  end

  def handle_event("change_media_editor", %{"media_editor" => params}, socket) do
    {:noreply, MediaEditor.update(socket, params, &reload_shell/2)}
  end

  def handle_event("save_media_editor", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.persist_socket(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("toggle_media_editor_quick_actions", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.toggle_quick_actions(socket, media_id, &reload_shell/2)}
  end

  def handle_event("replace_media_editor_file", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.replace_file(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("detect_media_editor_language", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.detect_language(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("toggle_media_post_picker", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.toggle_post_picker(socket, media_id, &reload_shell/2)}
  end

  def handle_event("change_media_post_picker", %{"id" => media_id, "media_post_picker" => %{"query" => query}}, socket) do
    {:noreply, MediaEditor.set_post_picker_query(socket, media_id, query, &reload_shell/2)}
  end

  def handle_event("link_media_to_post", %{"id" => media_id, "post-id" => post_id}, socket) do
    {:noreply, MediaEditor.link_post(socket, media_id, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("unlink_media_from_post", %{"id" => media_id, "post-id" => post_id}, socket) do
    {:noreply, MediaEditor.unlink_post(socket, media_id, post_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("edit_media_translation", %{"id" => media_id, "language" => language}, socket) do
    {:noreply, MediaEditor.edit_translation(socket, media_id, language, &reload_shell/2)}
  end

  def handle_event("change_media_translation", %{"media_translation" => params}, socket) do
    case socket.assigns.current_tab do
      %{type: :media, id: media_id} -> {:noreply, MediaEditor.update_translation(socket, media_id, params, &reload_shell/2)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("save_media_translation", %{"id" => media_id}, socket) do
    {:noreply, MediaEditor.save_translation(socket, media_id, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("refresh_media_translation", %{"id" => media_id, "language" => language}, socket) do
    {:noreply, MediaEditor.refresh_translation(socket, media_id, language, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("delete_media_translation", %{"id" => media_id, "language" => language}, socket) do
    {:noreply, MediaEditor.delete_translation(socket, media_id, language, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("close_media_translation_editor", _params, socket) do
    case socket.assigns.current_tab do
      %{type: :media, id: media_id} ->
        {:noreply,
         socket
         |> assign(:media_editor_translation_forms, Map.delete(socket.assigns.media_editor_translation_forms, media_id))
         |> reload_shell(socket.assigns.workbench)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("change_settings_search", %{"query" => query}, socket) do
    {:noreply, SettingsEditor.update_search(socket, query, &reload_shell/2)}
  end

  def handle_event("change_settings_project", %{"settings_project" => params}, socket) do
    {:noreply, SettingsEditor.update_project_draft(socket, params, &reload_shell/2)}
  end

  def handle_event("change_settings_editor", %{"settings_editor" => params}, socket) do
    {:noreply, SettingsEditor.update_editor_draft(socket, params, &reload_shell/2)}
  end

  def handle_event("save_settings_editor", _params, socket) do
    {:noreply, SettingsEditor.save_editor(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("save_settings_project", _params, socket) do
    {:noreply, SettingsEditor.save_project(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_settings_publishing", %{"settings_publishing" => params}, socket) do
    {:noreply, SettingsEditor.update_publishing_draft(socket, params, &reload_shell/2)}
  end

  def handle_event("change_settings_ai", %{"settings_ai" => params}, socket) do
    {:noreply, SettingsEditor.update_ai_draft(socket, params, &reload_shell/2)}
  end

  def handle_event("refresh_settings_ai_models", %{"endpoint" => endpoint}, socket) do
    endpoint_key = String.to_existing_atom(endpoint)
    {:noreply, SettingsEditor.refresh_ai_models(socket, endpoint_key, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("save_settings_ai", _params, socket) do
    {:noreply, SettingsEditor.save_ai(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("reset_settings_ai_prompt", _params, socket) do
    {:noreply, SettingsEditor.reset_ai_prompt(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("save_settings_publishing", _params, socket) do
    {:noreply, SettingsEditor.save_publishing(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("clear_settings_publishing", _params, socket) do
    {:noreply, SettingsEditor.clear_publishing(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_settings_new_category", %{"name" => name}, socket) do
    {:noreply, SettingsEditor.update_new_category(socket, name, &reload_shell/2)}
  end

  def handle_event("add_settings_category", _params, socket) do
    {:noreply, SettingsEditor.add_category(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("reset_settings_categories", _params, socket) do
    {:noreply, SettingsEditor.reset_categories(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("save_settings_category", %{"category_settings" => params}, socket) do
    {:noreply, SettingsEditor.save_category(socket, params, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("remove_settings_category", %{"category" => category}, socket) do
    {:noreply, SettingsEditor.remove_category(socket, category, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("settings_shell_command", %{"action" => action}, socket) do
    {:noreply, apply_shell_command(socket, action)}
  end

  def handle_event("toggle_settings_mcp_agent", %{"agent" => agent}, socket) do
    {:noreply, SettingsEditor.toggle_mcp_agent(socket, agent, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("select_style_theme", %{"theme" => theme}, socket) do
    {:noreply, SettingsEditor.select_style_theme(socket, theme, &reload_shell/2)}
  end

  def handle_event("change_style_preview_mode", %{"mode" => mode}, socket) do
    {:noreply, SettingsEditor.change_style_preview_mode(socket, mode, &reload_shell/2)}
  end

  def handle_event("apply_style_theme", _params, socket) do
    {:noreply, SettingsEditor.apply_style_theme(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("menu_editor_select_item", %{"item_id" => item_id}, socket) do
    {:noreply, MenuEditor.select_item(socket, item_id, &reload_shell/2)}
  end

  def handle_event("change_menu_editor_entry", %{"menu_editor_entry" => params}, socket) do
    {:noreply, MenuEditor.change_entry(socket, params, &reload_shell/2)}
  end

  def handle_event("submit_menu_editor_entry", _params, socket) do
    {:noreply, MenuEditor.submit_entry(socket, &reload_shell/2)}
  end

  def handle_event("cancel_menu_editor_entry", _params, socket) do
    {:noreply, MenuEditor.cancel_entry(socket, &reload_shell/2)}
  end

  def handle_event("select_menu_editor_page", %{"post_id" => post_id}, socket) do
    {:noreply, MenuEditor.select_page(socket, post_id, &reload_shell/2)}
  end

  def handle_event("select_menu_editor_category", %{"name" => name}, socket) do
    {:noreply, MenuEditor.select_category(socket, name, &reload_shell/2)}
  end

  def handle_event("menu_editor_toolbar_action", %{"action" => action}, socket) do
    {:noreply, MenuEditor.toolbar_action(socket, action, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event(
        "menu_editor_drop_item",
        %{"drag_item_id" => drag_item_id, "target_item_id" => target_item_id, "position" => position},
        socket
      ) do
    {:noreply, MenuEditor.drop_item(socket, drag_item_id, target_item_id, position, &reload_shell/2)}
  end

  def handle_event("menu_editor_keydown", %{"key" => key}, socket) do
    {:noreply, MenuEditor.handle_keydown(socket, key, &reload_shell/2)}
  end

  def handle_event("toggle_tag_selection", %{"name" => tag_name}, socket) do
    {:noreply, TagsEditor.toggle_selection(socket, tag_name, &reload_shell/2)}
  end

  def handle_event("change_new_tag_editor", %{"new_tag" => params}, socket) do
    {:noreply, TagsEditor.update_new_tag(socket, params, &reload_shell/2)}
  end

  def handle_event("create_tag_editor", _params, socket) do
    {:noreply, TagsEditor.create_tag(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_edit_tag_editor", %{"edit_tag" => params}, socket) do
    {:noreply, TagsEditor.update_edit_tag(socket, params, &reload_shell/2)}
  end

  def handle_event("save_tag_editor", _params, socket) do
    {:noreply, TagsEditor.save_tag(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("delete_tag_editor", _params, socket) do
    {:noreply, TagsEditor.delete_selected(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_merge_target", %{"target" => target}, socket) do
    {:noreply, TagsEditor.update_merge_target(socket, target, &reload_shell/2)}
  end

  def handle_event("merge_tags_editor", _params, socket) do
    {:noreply, TagsEditor.merge_selected(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("sync_tags_editor", _params, socket) do
    {:noreply, TagsEditor.sync(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_script_editor", %{"script_editor" => params}, socket) do
    {:noreply, CodeEntityEditor.update_script(socket, params, &reload_shell/2)}
  end

  def handle_event("save_script_editor", _params, socket) do
    {:noreply, CodeEntityEditor.save_script(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("run_script_editor", _params, socket) do
    {:noreply, CodeEntityEditor.run_script(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("check_script_editor", _params, socket) do
    {:noreply, CodeEntityEditor.check_script(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("delete_script_editor", _params, socket) do
    {:noreply, CodeEntityEditor.delete_script(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("change_template_editor", %{"template_editor" => params}, socket) do
    {:noreply, CodeEntityEditor.update_template(socket, params, &reload_shell/2)}
  end

  def handle_event("save_template_editor", _params, socket) do
    {:noreply, CodeEntityEditor.save_template(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("validate_template_editor", _params, socket) do
    {:noreply, CodeEntityEditor.validate_template(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("delete_template_editor", _params, socket) do
    {:noreply, CodeEntityEditor.delete_template(socket, &reload_shell/2, &append_output_entry/5)}
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
     |> clear_chat_action_error()
     |> open_sidebar_item(%{"route" => "settings", "id" => "settings-ai", "title" => "Settings", "subtitle" => "AI"}, :pin)}
  end

  def handle_event("change_chat_surface_form", %{"surface" => %{"id" => surface_id, "fields" => fields}}, socket) do
    {:noreply, ChatEditor.update_surface_form(socket, surface_id, fields, &reload_shell/2)}
  end

  def handle_event("select_chat_surface_tab", %{"surface-id" => surface_id, "index" => index}, socket) do
    {:noreply, ChatEditor.select_surface_tab(socket, surface_id, parse_integer(index), &reload_shell/2)}
  end

  def handle_event("chat_surface_action", params, socket) do
    {:noreply, handle_chat_surface_action(socket, params)}
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
      {:rerun, next_socket} -> {:noreply, apply_shell_command(next_socket, "validate_translations")}
      {:socket, next_socket} -> {:noreply, next_socket}
    end
  end

  def handle_event("select_git_diff_file", %{"path" => path}, socket) do
    {:noreply, socket |> MiscEditor.select_git_diff_file(path) |> assign_misc_editor()}
  end

  def handle_event("toggle_duplicate_pair", %{"pair-id" => pair_id}, socket) do
    {:noreply, MiscEditor.toggle_duplicate(socket, pair_id, &reload_shell/2)}
  end

  def handle_event("dismiss_duplicate_pair", %{"post-id-a" => post_id_a, "post-id-b" => post_id_b}, socket) do
    {:noreply, MiscEditor.dismiss_duplicate(socket, post_id_a, post_id_b, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("dismiss_selected_duplicates", _params, socket) do
    {:noreply, MiscEditor.dismiss_selected(socket, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_event("repair_metadata_diff", %{"field" => field, "direction" => direction}, socket) do
    case MiscEditor.metadata_diff_repair_request(socket, field, direction) do
      {:ok, params} -> {:noreply, apply_shell_command(socket, "repair_metadata_diff", params)}
      {:error, message} -> {:noreply, append_output_entry(socket, translate_for_socket(socket, "Metadata Diff"), message, nil, "error")}
    end
  end

  def handle_event("import_metadata_diff_orphans", _params, socket) do
    case MiscEditor.metadata_diff_orphan_import_request(socket) do
      {:ok, params} -> {:noreply, apply_shell_command(socket, "import_metadata_diff_orphans", params)}
      {:error, message} -> {:noreply, append_output_entry(socket, translate_for_socket(socket, "Metadata Diff"), message, nil, "error")}
    end
  end

  def handle_event("select_metadata_diff_tab", %{"tab" => tab}, socket) do
    tab_id = socket.assigns.current_tab.id

    socket =
      socket
      |> assign(:metadata_diff_active_tabs, Map.put(socket.assigns.metadata_diff_active_tabs, tab_id, tab))
      |> assign(:metadata_diff_field_filters, Map.delete(socket.assigns.metadata_diff_field_filters, tab_id))
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

    {:noreply, socket |> assign(:metadata_diff_field_filters, next_filters) |> assign_misc_editor()}
  end

  def handle_event("open_duplicate_post", %{"id" => id, "title" => title}, socket) do
    {:noreply, open_sidebar_item(socket, %{"route" => "post", "id" => id, "title" => title, "subtitle" => "draft"}, :preview)}
  end

  def handle_event("open_overlay", %{"kind" => kind}, socket) do
    socket =
      case socket.assigns[:current_tab] do
        %{type: :post, id: post_id} when kind in ["ai_suggestions", "language_picker"] ->
          assign(socket, :post_editor_quick_actions_open, Map.put(socket.assigns.post_editor_quick_actions_open, post_id, false))

        %{type: :media, id: media_id} when kind in ["ai_suggestions", "language_picker", "confirm_delete"] ->
          assign(socket, :media_editor_quick_actions_open, Map.put(socket.assigns.media_editor_quick_actions_open, media_id, false))

        _other ->
          socket
      end

    overlay =
      with overlay_kind when not is_nil(overlay_kind) <- ShellOverlayComponents.kind(kind),
           %{type: route} <- socket.assigns[:current_tab] do
        tab = socket.assigns.current_tab
        title = tab_title(tab, socket.assigns.tab_meta)
        subtitle = tab_subtitle(tab, socket.assigns.tab_meta)
        Overlay.open(route, overlay_kind, ShellOverlayComponents.context(socket.assigns, title, subtitle))
      end

    {:noreply, assign(socket, :shell_overlay, overlay)}
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :shell_overlay, nil)}
  end

  def handle_event("overlay_keydown", %{"key" => key}, socket) do
    socket =
      case {socket.assigns[:shell_overlay], key} do
        {nil, _other} -> socket
        {_overlay, "Escape"} -> assign(socket, :shell_overlay, nil)
        {%{kind: :gallery} = overlay, "ArrowLeft"} -> assign(socket, :shell_overlay, Overlay.lightbox_previous(overlay))
        {%{kind: :gallery} = overlay, "ArrowRight"} -> assign(socket, :shell_overlay, Overlay.lightbox_next(overlay))
        _other -> socket
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
    {:noreply, update_shell_overlay(socket, &Overlay.set_active_tab(&1, ShellOverlayComponents.tab(tab)))}
  end

  def handle_event("overlay_update_form", %{"overlay" => params}, socket) do
    socket =
      socket
      |> update_shell_overlay(&Overlay.update_form_value(&1, :external_url, Map.get(params, "url", "")))
      |> update_shell_overlay(&Overlay.update_form_value(&1, :external_text, Map.get(params, "text", "")))

    {:noreply, socket}
  end

  def handle_event("overlay_select_result", %{"id" => id}, socket) do
    overlay = socket.assigns[:shell_overlay]
    current_tab = socket.assigns[:current_tab]

    socket =
      case {overlay, current_tab} do
        {%{kind: :insert_link}, %{type: :post, id: post_id}} ->
          case Overlay.insert_link_result(overlay, id) do
            nil -> socket
            result -> PostEditor.insert_content(socket, post_id, ShellOverlayComponents.markdown_link(result.title, result.canonical_url), &reload_shell/2)
          end

        {%{kind: :insert_media}, %{type: :post, id: post_id}} ->
          case Overlay.insert_media_result(overlay, id) do
            nil -> socket
            result ->
              syntax =
                if result.is_image do
                  "![#{result.title}](bds-media://#{result.media_id})"
                else
                  "[#{result.original_name}](bds-media://#{result.media_id})"
                end

              PostEditor.insert_content(socket, post_id, syntax, &reload_shell/2)
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
            PostEditor.insert_content(socket, post_id, details, &reload_shell/2)
          else
            socket
          end

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
          PostEditor.translate(socket, post_id, code, &reload_shell/2, &append_output_entry/5)

        {%{kind: :language_picker}, %{type: :media, id: media_id}} ->
          MediaEditor.translate(socket, media_id, code, &reload_shell/2, &append_output_entry/5)

        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_confirm", _params, socket) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :ai_suggestions} = overlay, %{type: :post, id: post_id}} ->
          PostEditor.apply_ai_suggestions(
            socket,
            post_id,
            Overlay.selected_ai_fields(overlay),
            &reload_shell/2,
            &append_output_entry/5
          )

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
    {:noreply, activate_project(socket, project_id, "Select Project", fn project -> "Activated #{project.name}" end)}
  end

  def handle_event("create_project", _params, socket) do
    attrs = %{name: next_project_name(socket.assigns.projects.projects)}

    socket =
      case Projects.create_project(attrs) do
        {:ok, project} -> activate_project(socket, project.id, "New Project", fn created -> "Activated #{created.name}" end)
        {:error, reason} -> append_output_entry(socket, "New Project", inspect(reason), nil, "error")
      end

    {:noreply, socket}
  end

  def handle_event("import_project", _params, socket) do
    socket =
      case FolderPicker.choose_directory("Open Existing Blog") do
        {:ok, path} ->
          name = path |> Path.basename() |> String.trim() |> case do
            "" -> "Imported Blog"
            value -> value
          end

          case Projects.create_project(%{name: name, data_path: path}) do
            {:ok, project} -> activate_project(socket, project.id, "Open Existing Blog", fn imported -> "Activated #{imported.name}" end)
            {:error, reason} -> append_output_entry(socket, "Open Existing Blog", inspect(reason), nil, "error")
          end

        :cancel -> assign(socket, :project_menu_open, false)
        {:error, %{message: message}} -> append_output_entry(socket, "Open Existing Blog", message, nil, "error")
      end

    {:noreply, socket}
  end

  def handle_event("change_ui_language", %{"ui_language" => language}, socket) do
    {:noreply, set_page_language(socket, language)}
  end

  def handle_event("sync_ui_language", %{"language" => language}, socket) do
    {:noreply, set_page_language(socket, language)}
  end

  def handle_event("restore_workbench_session", %{"session" => session_payload}, socket) when is_map(session_payload) do
    {:noreply, reload_shell(socket, restore_workbench_session(session_payload))}
  end

  def handle_event("native_menu_action", %{"action" => action}, socket) do
    {:noreply, handle_native_menu_action(socket, action)}
  end

  def handle_event("titlebar_menu_keydown", %{"key" => key}, socket) do
    {:noreply, handle_titlebar_menu_keydown(socket, key)}
  end

  def handle_event("toggle_titlebar_menu", %{"group" => group}, socket) do
    {:noreply,
     if(socket.assigns.titlebar_menu_group == group,
       do: close_titlebar_menu(socket),
       else: open_titlebar_menu(socket, group)
     )}
  end

  def handle_event("hover_titlebar_menu", %{"group" => group}, socket) do
    socket =
      if socket.assigns.titlebar_menu_group do
        open_titlebar_menu(socket, group)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_titlebar_menu", _params, socket) do
    {:noreply, close_titlebar_menu(socket)}
  end

  def handle_event("titlebar_menu_action", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> close_titlebar_menu()
     |> handle_native_menu_action(action)}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, ChatEditor.finish_request(socket, ref, result, &reload_shell/2, &append_output_entry/5)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    next_socket =
      case reason do
        :normal -> socket
        _other -> ChatEditor.finish_request(socket, ref, {:error, :cancelled}, &reload_shell/2, &append_output_entry/5)
      end

    {:noreply, next_socket}
  end

  def handle_info({:chat_tool_call, conversation_id, tool_call}, socket) do
    {:noreply, ChatEditor.note_tool_call(socket, conversation_id, tool_call, &reload_shell/2)}
  end

  def handle_info({:chat_tool_result, conversation_id, name}, socket) do
    {:noreply, ChatEditor.note_tool_result(socket, conversation_id, name, &reload_shell/2)}
  end

  def handle_info({:chat_streaming_content, conversation_id, content}, socket) do
    {:noreply, ChatEditor.note_streaming_content(socket, conversation_id, content, &reload_shell/2)}
  end

  def handle_info(:refresh_task_status, socket) do
    raw_task_status = BDS.Tasks.status_snapshot()

    case next_completed_task_result(socket, raw_task_status) do
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
         |> mark_task_result_handled(task.id)
         |> apply_shell_command_result(task.result)}
    end
  end

  @impl true
  def render(assigns) do
    Process.put(:bds_ui_locale, assigns.page_language)
    index(assigns)
  end

  defp reload_shell(socket, workbench) do
    projects = ShellData.project_snapshot()
    dashboard = ShellData.dashboard(projects.active_project_id)
    git_badge_count = ShellData.git_badge_count(projects.active_project_id)
    active_view_id = Atom.to_string(workbench.active_view)
    sidebar_data = ShellData.sidebar_view(projects.active_project_id, active_view_id, ShellSidebarState.current_filters(socket, active_view_id))
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
    |> assign(:workbench, workbench)
    |> assign(:projects, projects)
    |> assign(:current_project, ShellData.current_project(projects))
    |> assign(:dashboard, dashboard)
    |> assign(:dashboard_timeline_entries, Map.get(dashboard, :timeline_entries, []))
    |> assign(:dashboard_category_counts, Map.get(dashboard, :category_counts, []))
    |> assign(:dashboard_recent_posts, Map.get(dashboard, :recent_posts, []))
    |> assign(:dashboard_tag_cloud_items, ShellData.dashboard_tag_cloud_items(Map.get(dashboard, :tag_cloud_items, [])))
    |> assign(:sidebar_data, sidebar_data)
    |> assign(:sidebar_header, active_sidebar_label(activity_buttons, workbench.active_view, sidebar_data))
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
    |> assign(:menu_groups, socket.assigns[:menu_groups] || titlebar_menu_groups())
    |> assign(:titlebar_menu_item_index, socket.assigns[:titlebar_menu_item_index])
    |> assign(:current_tab, current_tab(workbench))
    |> assign_post_editor()
    |> assign_media_editor()
    |> assign_settings_editor()
    |> assign_menu_editor()
    |> assign_tags_editor()
    |> assign_code_entity_editor()
    |> assign_chat_editor()
    |> assign_misc_editor()
  end

  defp render_panel_body(assigns) do
    case assigns.workbench.panel.active_tab do
      :tasks -> render_task_entries(assigns)
      :output -> render_output_entries(assigns)
      :post_links -> render_post_links(assigns)
      :git_log -> render_git_log(assigns)
      other -> render_generic_panel(assigns, other)
    end
  end

  defp render_editor_toolbar(assigns) do
    buttons = editor_toolbar_buttons(assigns.current_tab)
    assigns = assign(assigns, :editor_toolbar_buttons, buttons)

    ~H"""
    <%= if Enum.any?(@editor_toolbar_buttons) do %>
      <div class="editor-toolbar">
        <%= for button <- @editor_toolbar_buttons do %>
          <button
            class={["editor-toolbar-button", if(button.destructive, do: "is-destructive")]}
            data-testid="editor-toolbar-overlay-button"
            type="button"
            phx-click="open_overlay"
            phx-value-kind={button.kind}
          >
            <%= translated(button.label) %>
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_task_entries(assigns) do
    ~H"""
    <%= if Enum.empty?(Map.get(@task_status, :tasks, [])) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Tasks") %></strong>
        <span><%= translated("No background tasks running") %></span>
      </div>
    <% else %>
      <div class="task-list">
        <%= for task <- Map.get(@task_status, :tasks, []) do %>
          <div class="panel-entry task-entry">
            <div class="task-entry-header">
              <strong><%= task.name %></strong>
              <span class={"task-status task-status-#{task.status}"}><%= Map.get(task, :status_label, task.status |> to_string() |> String.capitalize()) %></span>
            </div>
            <span><%= task.message || task.group_name || "" %></span>
            <%= if is_number(task.progress) do %>
              <div class="task-progress-row">
                <progress max="1" value={task.progress}></progress>
                <span><%= Map.get(task, :progress_label, progress_percent(task.progress)) %></span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_output_entries(assigns) do
    ~H"""
    <%= if Enum.empty?(@output_entries) do %>
      <div class="panel-entry panel-empty-state output-list">
        <strong><%= translated("Output") %></strong>
        <span><%= translated("No shell output yet") %></span>
      </div>
    <% else %>
      <div class="output-list">
        <%= for entry <- @output_entries do %>
          <div class={[
            "panel-entry",
            "output-entry",
            if(Map.get(entry, :level) == "error", do: "output-entry-error")
          ]}>
            <strong><%= entry.title %></strong>
            <span><%= entry.message %></span>
            <%= if present?(entry.details) do %>
              <span><%= entry.details %></span>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_post_links(assigns) do
    links = post_link_entries(assigns)

    assigns =
      assigns
      |> assign(:backlinks, Map.get(links, :backlinks, []))
      |> assign(:outlinks, Map.get(links, :outlinks, []))

    ~H"""
    <%= if Enum.empty?(@backlinks) and Enum.empty?(@outlinks) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Post Links") %></strong>
        <span><%= translated("No post links yet") %></span>
      </div>
    <% else %>
      <div class="git-log-list">
        <%= if Enum.any?(@backlinks) do %>
          <div class="panel-entry"><strong><%= translated("Backlinks") %></strong></div>
          <%= for entry <- @backlinks do %>
            <button
              class="panel-entry task-entry"
              type="button"
              phx-click="pin_sidebar_item"
              phx-value-route="post"
              phx-value-id={entry.id}
              phx-value-title={entry.title}
              phx-value-subtitle="linked post"
            >
              <strong><%= entry.title %></strong>
              <span><%= entry.text %></span>
            </button>
          <% end %>
        <% end %>

        <%= if Enum.any?(@outlinks) do %>
          <div class="panel-entry"><strong><%= translated("Links To") %></strong></div>
          <%= for entry <- @outlinks do %>
            <button
              class="panel-entry task-entry"
              type="button"
              phx-click="pin_sidebar_item"
              phx-value-route="post"
              phx-value-id={entry.id}
              phx-value-title={entry.title}
              phx-value-subtitle="linked post"
            >
              <strong><%= entry.title %></strong>
              <span><%= entry.text %></span>
            </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_git_log(assigns) do
    entries = git_log_entries(assigns)
    assigns = assign(assigns, :git_entries, entries)

    ~H"""
    <%= if Enum.empty?(@git_entries) do %>
      <div class="git-log-list">
        <div class="panel-entry panel-empty-state">
          <strong><%= translated("Git Log") %></strong>
          <span><%= translated("No git history yet") %></span>
        </div>
      </div>
    <% else %>
      <div class="git-log-list">
        <%= for entry <- @git_entries do %>
          <div class="panel-entry task-entry">
            <strong><%= short_commit_hash(entry.hash) %> <%= entry.subject || translated("No commit subject") %></strong>
            <span><%= entry.hash %></span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_generic_panel(assigns, tab) do
    assigns = assign(assigns, :panel_label, ShellData.route_label(tab))

    ~H"""
    <div class="panel-entry">
      <strong><%= @panel_label %></strong>
      <span><%= translated("The shared lower panel is available for tasks, output, git details, and editor-specific diagnostics.") %></span>
    </div>
    """
  end

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

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

  defp present?(value), do: value not in [nil, ""]

  defp timeline_height(entry, entries) do
    max_count =
      entries
      |> Enum.map(&(&1.count || 0))
      |> Enum.max(fn -> 1 end)

    max(4, ((entry.count || 0) / max_count) * 100)
  end

  defp current_tab(%{active_tab: nil}), do: nil

  defp current_tab(%{tabs: tabs, active_tab: {type, id}}) do
    Enum.find(tabs, &(&1.type == type and &1.id == id))
  end

  defp assign_post_editor(socket) do
    PostEditor.assign_socket(socket)
  end

  defp assign_media_editor(socket) do
    MediaEditor.assign_socket(socket)
  end

  defp assign_settings_editor(socket) do
    SettingsEditor.assign_socket(socket)
  end

  defp assign_menu_editor(socket) do
    MenuEditor.assign_socket(socket)
  end

  defp assign_tags_editor(socket) do
    TagsEditor.assign_socket(socket)
  end

  defp assign_code_entity_editor(socket) do
    CodeEntityEditor.assign_socket(socket)
  end

  defp assign_chat_editor(socket) do
    ChatEditor.assign_socket(socket)
  end

  defp assign_misc_editor(socket) do
    MiscEditor.assign_socket(socket)
  end


  defp sync_layout(workbench, params) do
    workbench
    |> maybe_set_sidebar_width(Map.get(params, "sidebar_width"))
    |> maybe_set_assistant_width(Map.get(params, "assistant_sidebar_width"))
  end

  defp resize_panel(workbench, "sidebar", width) do
    workbench
    |> Workbench.set_sidebar_width(parse_width(width))
    |> Map.put(:sidebar_visible, true)
  end

  defp resize_panel(workbench, "assistant", width) do
    workbench
    |> Workbench.set_assistant_sidebar_width(parse_width(width))
    |> Map.put(:assistant_sidebar_visible, true)
  end

  defp resize_panel(workbench, _target, _width), do: workbench

  defp maybe_set_sidebar_width(workbench, nil), do: workbench
  defp maybe_set_sidebar_width(workbench, width), do: Workbench.set_sidebar_width(workbench, parse_width(width))

  defp maybe_set_assistant_width(workbench, nil), do: workbench

  defp maybe_set_assistant_width(workbench, width) do
    Workbench.set_assistant_sidebar_width(workbench, parse_width(width))
  end

  defp parse_width(width) when is_integer(width), do: width

  defp parse_width(width) when is_binary(width) do
    case Integer.parse(width) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp ignore_shortcut?(params) do
    Map.get(params, "alt", false) or
      Map.get(params, "contentEditable", false) or
      Map.get(params, "content_editable", false) or
      Map.get(params, "tag") in ["INPUT", "TEXTAREA", "SELECT"] or
      Map.get(params, :tag) in ["INPUT", "TEXTAREA", "SELECT"]
  end

  defp create_sidebar_item(socket, kind) do
    case socket.assigns.projects.active_project_id do
      project_id when is_binary(project_id) -> create_sidebar_item(socket, project_id, kind)
      _other -> reload_shell(socket, socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, project_id, "post") do
    case BDS.Posts.create_post(%{project_id: project_id, title: "", content: "", tags: [], categories: []}) do
      {:ok, _post} -> reload_shell(socket, socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output_entry(translated("sidebar.newPost"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, project_id, "media") do
    case FilePicker.choose_file(translated("sidebar.importMedia")) do
      {:ok, source_path} ->
        case BDS.Media.import_media(%{project_id: project_id, source_path: source_path}) do
          {:ok, _media} -> reload_shell(socket, socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output_entry(translated("sidebar.importMedia"), inspect(reason), nil, "error")
            |> reload_shell(socket.assigns.workbench)
        end

      :cancel ->
        reload_shell(socket, socket.assigns.workbench)

      {:error, %{message: message}} ->
        socket
        |> append_output_entry(translated("sidebar.importMedia"), message, nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, project_id, "script") do
    case Scripts.create_script(%{
           project_id: project_id,
           title: translated("sidebar.scripts.newScript"),
           kind: :utility,
           content: "print(\"new script\")",
           entrypoint: "main",
           enabled: true
         }) do
      {:ok, script} ->
        open_sidebar_item(socket, %{"route" => "scripts", "id" => script.id, "title" => script.title, "subtitle" => "Automation helpers"}, :pin)

      {:error, reason} ->
        socket
        |> append_output_entry(translated("sidebar.scripts.newScript"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, project_id, "template") do
    case Templates.create_template(%{
           project_id: project_id,
           title: translated("sidebar.templates.newTemplate"),
           kind: :post,
           content: "",
           enabled: true
         }) do
      {:ok, template} ->
        open_sidebar_item(socket, %{"route" => "templates", "id" => template.id, "title" => template.title, "subtitle" => "Site rendering"}, :pin)

      {:error, reason} ->
        socket
        |> append_output_entry(translated("sidebar.templates.newTemplate"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, project_id, "import") do
    case ImportDefinitions.create_definition(%{project_id: project_id, name: translated("sidebar.import.newDefinition")}) do
      {:ok, definition} ->
        open_sidebar_item(socket, %{"route" => "import", "id" => definition.id, "title" => definition.name, "subtitle" => "Import definitions"}, :pin)

      {:error, reason} ->
        socket
        |> append_output_entry(translated("sidebar.import.newDefinition"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp create_sidebar_item(socket, _project_id, _kind), do: reload_shell(socket, socket.assigns.workbench)

  defp open_sidebar_item(socket, params, intent) do
    route_atom = sidebar_route_atom(Map.fetch!(params, "route"))
    tab_id = tab_id_for_route(route_atom, Map.fetch!(params, "id"))

    workbench =
      Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, tab_intent(route_atom, intent))

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

  defp sidebar_create_action(:posts), do: %{kind: "post", label: "sidebar.newPost"}
  defp sidebar_create_action(:media), do: %{kind: "media", label: "sidebar.importMedia"}
  defp sidebar_create_action(:scripts), do: %{kind: "script", label: "sidebar.scripts.newScript"}
  defp sidebar_create_action(:templates), do: %{kind: "template", label: "sidebar.templates.newTemplate"}
  defp sidebar_create_action(:import), do: %{kind: "import", label: "sidebar.import.newDefinition"}
  defp sidebar_create_action(_view), do: nil

  defp set_page_language(socket, language) do
    codes = Enum.map(socket.assigns[:supported_ui_languages] || ShellData.supported_ui_languages(), & &1.code)

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
      project_id == socket.assigns.projects.active_project_id -> assign(socket, :project_menu_open, false)
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

  defp next_project_name(projects) do
    existing_names = MapSet.new(Enum.map(projects, & &1.name))

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = if index == 1, do: @default_new_project_name, else: "#{@default_new_project_name} #{index}"
      if MapSet.member?(existing_names, candidate), do: nil, else: candidate
    end)
  end

  defp handle_native_menu_action(socket, action) do
    with action_atom when not is_nil(action_atom) <- safe_existing_atom(action) do
      if MapSet.member?(@local_menu_actions, action_atom) do
        reload_shell(socket, MenuBar.execute(socket.assigns.workbench, action_atom))
      else
        apply_shell_command(socket, action)
      end
    else
      _other -> append_output_entry(socket, "Menu", "Unsupported shell command", action, "error")
    end
  end

  defp restore_workbench_session(session_payload) do
    Session.restore(session_payload)
  rescue
    _error -> Workbench.new()
  end

  defp safe_existing_atom(action) when is_binary(action) do
    String.to_existing_atom(action)
  rescue
    ArgumentError -> nil
  end

  defp apply_shell_command(socket, action, params \\ %{}) do
    case ShellCommands.execute(action, params) do
      {:ok, result} -> apply_shell_command_result(socket, result)
      {:error, %{message: message}} -> append_output_entry(socket, command_title(action), message, nil, "error")
      {:error, reason} -> append_output_entry(socket, command_title(action), inspect(reason), nil, "error")
    end
  end

  defp apply_shell_command_result(socket, %{kind: "task_queued", title: title, message: message, panel_tab: panel_tab}) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(String.to_existing_atom(panel_tab))

    socket
    |> append_output_entry(translate_for_socket(socket, title), translate_for_socket(socket, message))
    |> reload_shell(workbench)
  end

  defp apply_shell_command_result(socket, %{kind: "output", title: title, message: message} = result) do
    socket
    |> append_output_entry(translate_for_socket(socket, title), translate_for_socket(socket, message), Map.get(result, :details), Map.get(result, :level, "info"))
  end

  defp apply_shell_command_result(socket, %{kind: "open_url", title: title, message: message, url: url}) do
    append_output_entry(socket, translate_for_socket(socket, title), translate_for_socket(socket, message), url)
  end

  defp apply_shell_command_result(socket, %{kind: "open_editor", route: route, title: title, subtitle: subtitle} = result) do
    route_atom = String.to_existing_atom(route)
    tab_id = tab_id_for_route(route_atom, route)
    workbench = Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, :pin)

    tab_meta =
      Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{
        title: translate_for_socket(socket, title),
        subtitle: translate_for_socket(socket, subtitle),
        action: Map.get(result, :action),
        payload: Map.get(result, :payload),
        project_id: Map.get(result, :project_id),
        editor_meta: translate_editor_meta(Map.get(result, :editorMeta, []), socket.assigns.page_language)
      })

    socket
    |> assign(:tab_meta, tab_meta)
    |> reload_shell(workbench)
  end

  defp apply_shell_command_result(socket, _result), do: socket

  defp initial_handled_task_results do
    BDS.Tasks.status_snapshot()
    |> Map.get(:tasks, [])
    |> Enum.filter(fn task -> task.status == :completed and is_map(task.result) end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp next_completed_task_result(socket, task_status) do
    handled = Map.get(socket.assigns, :handled_task_results, MapSet.new())

    Enum.find(Map.get(task_status, :tasks, []), fn task ->
      task.status == :completed and is_map(task.result) and not MapSet.member?(handled, task.id)
    end)
  end

  defp mark_task_result_handled(socket, task_id) do
    handled = Map.get(socket.assigns, :handled_task_results, MapSet.new())
    assign(socket, :handled_task_results, MapSet.put(handled, task_id))
  end

  defp localize_task_status(task_status, locale) do
    tasks = Enum.map(Map.get(task_status, :tasks, []), &localize_task(&1, locale))
    active = Enum.filter(tasks, &(&1.status in [:running, :pending]))

    task_status
    |> Map.put(:tasks, tasks)
    |> Map.put(:running_task_message, localized_running_task_message(active, locale))
  end

  defp localize_task(task, locale) do
    progress = Map.get(task, :progress)

    task
    |> Map.put(:name, ShellData.translate(task.name, %{}, locale))
    |> Map.put(:message, localize_task_message(Map.get(task, :message), locale))
    |> Map.put(:group_name, localize_task_group(Map.get(task, :group_name), locale))
    |> Map.put(:status_label, localize_task_status_label(task.status, locale))
    |> Map.put(:progress_label, if(is_number(progress), do: progress_percent(progress), else: nil))
  end

  defp localize_task_message(nil, _locale), do: nil
  defp localize_task_message("", _locale), do: ""
  defp localize_task_message(message, locale), do: ShellData.translate(message, %{}, locale)

  defp localize_task_group(nil, _locale), do: nil
  defp localize_task_group(group, locale), do: ShellData.translate(group, %{}, locale)

  defp localize_task_status_label(status, locale) do
    status
    |> to_string()
    |> String.capitalize()
    |> ShellData.translate(%{}, locale)
  end

  defp localized_running_task_message([], _locale), do: nil

  defp localized_running_task_message([task | _rest], locale) do
    cond do
      task.status == :pending -> ShellData.translate("Queued", %{}, locale) <> ": " <> task.name
      is_binary(task.message) and task.message != "" -> task.name <> ": " <> task.message
      true -> task.name
    end
  end

  defp translate_editor_meta(items, locale) do
    Enum.map(items, fn item ->
      item
      |> Map.update(:label, nil, &ShellData.translate(&1, %{}, locale))
      |> Map.update(:value, nil, &translate_editor_meta_value(&1, locale))
    end)
  end

  defp translate_editor_meta_value(value, locale) when is_binary(value), do: ShellData.translate(value, %{}, locale)
  defp translate_editor_meta_value(value, _locale), do: value

  defp translate_for_socket(socket, text) when is_binary(text), do: ShellData.translate(text, %{}, socket.assigns.page_language)
  defp translate_for_socket(_socket, text), do: text

  defp progress_percent(progress) when is_number(progress) do
    percentage = progress |> Kernel.*(100) |> round()
    Integer.to_string(percentage) <> "%"
  end

  defp command_title(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp titlebar_menu_groups do
    DesktopMenuBar.groups(dev_mode?: Application.get_env(:bds, :dev_routes, false))
  end

  defp titlebar_menu_dropdown_items(group) do
    group.items
    |> Enum.map_reduce(0, fn item, keyboard_index ->
      if Map.get(item, :separator, false) do
        {%{separator: true}, keyboard_index}
      else
        {Map.put(item, :keyboard_index, keyboard_index), keyboard_index + 1}
      end
    end)
    |> elem(0)
  end

  defp titlebar_menu_item_active?(group, item, current_index) do
    cond do
      is_nil(current_index) ->
        false

      Map.get(item, :separator, false) ->
        false

      true ->
        group.items
        |> Enum.reject(&Map.get(&1, :separator, false))
        |> Enum.find_index(&(&1.id == item.id))
        |> Kernel.==(current_index)
    end
  end

  defp active_titlebar_menu_group(assigns) do
    Enum.find(assigns.menu_groups || [], fn group -> Atom.to_string(group.id) == assigns.titlebar_menu_group end)
  end

  defp active_titlebar_menu_items(assigns) do
    assigns
    |> active_titlebar_menu_group()
    |> case do
      nil -> []
      group -> Enum.reject(group.items, &Map.get(&1, :separator, false))
    end
  end

  defp open_titlebar_menu(socket, group) do
    socket
    |> assign(:titlebar_menu_group, group)
    |> assign(:titlebar_menu_item_index, nil)
  end

  defp close_titlebar_menu(socket) do
    socket
    |> assign(:titlebar_menu_group, nil)
    |> assign(:titlebar_menu_item_index, nil)
  end

  defp handle_titlebar_menu_keydown(socket, key) do
    if socket.assigns.titlebar_menu_group do
      case key do
        "Escape" ->
          close_titlebar_menu(socket)

        "ArrowRight" ->
          rotate_titlebar_menu_group(socket, 1)

        "ArrowLeft" ->
          rotate_titlebar_menu_group(socket, -1)

        "ArrowDown" ->
          advance_titlebar_menu_item_index(socket, 1)

        "ArrowUp" ->
          advance_titlebar_menu_item_index(socket, -1)

        "Home" ->
          set_first_titlebar_menu_item_index(socket)

        "End" ->
          set_last_titlebar_menu_item_index(socket)

        "Enter" ->
          invoke_active_titlebar_menu_item(socket)

        " " ->
          invoke_active_titlebar_menu_item(socket)

        _other ->
          socket
      end
    else
      socket
    end
  end

  defp rotate_titlebar_menu_group(socket, offset) do
    groups = socket.assigns.menu_groups || []
    current_group = socket.assigns.titlebar_menu_group
    current_index = Enum.find_index(groups, fn group -> Atom.to_string(group.id) == current_group end)

    if is_nil(current_index) or groups == [] do
      socket
    else
      next_index = rem(current_index + offset + length(groups), length(groups))
      next_group = Enum.at(groups, next_index)
      open_titlebar_menu(socket, Atom.to_string(next_group.id))
    end
  end

  defp advance_titlebar_menu_item_index(socket, offset) do
    items = active_titlebar_menu_items(socket.assigns)
    current_index = socket.assigns[:titlebar_menu_item_index]

    cond do
      items == [] ->
        socket

      current_index == nil and offset > 0 ->
        assign(socket, :titlebar_menu_item_index, 0)

      current_index == nil and offset < 0 ->
        assign(socket, :titlebar_menu_item_index, length(items) - 1)

      true ->
        next_index = rem(current_index + offset + length(items), length(items))
        assign(socket, :titlebar_menu_item_index, next_index)
    end
  end

  defp set_last_titlebar_menu_item_index(socket) do
    items = active_titlebar_menu_items(socket.assigns)

    if items == [] do
      socket
    else
      assign(socket, :titlebar_menu_item_index, length(items) - 1)
    end
  end

  defp set_first_titlebar_menu_item_index(socket) do
    items = active_titlebar_menu_items(socket.assigns)

    if items == [] do
      socket
    else
      assign(socket, :titlebar_menu_item_index, 0)
    end
  end

  defp invoke_active_titlebar_menu_item(socket) do
    items = active_titlebar_menu_items(socket.assigns)

    case Enum.at(items, socket.assigns[:titlebar_menu_item_index]) do
      %{id: id} ->
        socket
        |> close_titlebar_menu()
        |> handle_native_menu_action(Atom.to_string(id))

      _other ->
        socket
    end
  end

  defp mac_ui? do
    case Application.get_env(:bds, :shell_platform) do
      nil -> match?({:unix, :darwin}, :os.type())
      platform -> match?({:unix, :darwin}, platform)
    end
  end

  defp post_link_entries(assigns) do
    case assigns.current_tab do
      %{type: :post, id: post_id} ->
        %{
          backlinks: related_posts(PostLinks.list_incoming_links(post_id), :source_post_id),
          outlinks: related_posts(PostLinks.list_outgoing_links(post_id), :target_post_id)
        }

      _other ->
        %{backlinks: [], outlinks: []}
    end
  end

  defp related_posts(links, key) do
    Enum.map(links, fn link ->
      case Repo.get(Post, Map.fetch!(link, key)) do
        %Post{} = post -> %{id: post.id, title: post.title || post.slug || post.id, text: link.link_text || post.slug || post.id}
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp git_log_entries(assigns) do
    case git_history_target(assigns.current_tab) do
      nil -> []
      {project_id, file_path} ->
        case Git.file_history(project_id, file_path) do
          {:ok, %{commits: commits}} -> commits
          _other -> []
        end
    end
  end

  defp git_history_target(%{type: :post, id: post_id}) do
    case Repo.get(Post, post_id) do
      %Post{project_id: project_id, file_path: file_path} when file_path not in [nil, ""] -> {project_id, file_path}
      _other -> nil
    end
  end

  defp git_history_target(%{type: :media, id: media_id}) do
    case Repo.get(Media, media_id) do
      %Media{project_id: project_id, file_path: file_path} when file_path not in [nil, ""] -> {project_id, file_path}
      _other -> nil
    end
  end

  defp git_history_target(_tab), do: nil

  defp handle_chat_surface_action(socket, params) do
    surface_id = Map.get(params, "surface-id", "")

    payload =
      params
      |> Map.get("payload")
      |> decode_chat_surface_payload()
      |> maybe_put_chat_surface_form_data(socket, surface_id)

    case normalize_chat_action(Map.get(params, "action", "")) do
      :open_post ->
        case Map.get(payload, "postId") || Map.get(payload, "post_id") do
          post_id when is_binary(post_id) and post_id != "" ->
            socket
            |> clear_chat_action_error()
            |> open_sidebar_item(%{"route" => "post", "id" => post_id, "title" => post_title(post_id), "subtitle" => post_subtitle(post_id)}, :pin)

          _other ->
            ChatEditor.set_action_error(socket, socket.assigns.current_tab.id, "Invalid payload for openPost action", &reload_shell/2)
        end

      :open_media ->
        case Map.get(payload, "mediaId") || Map.get(payload, "media_id") do
          media_id when is_binary(media_id) and media_id != "" ->
            socket
            |> clear_chat_action_error()
            |> open_sidebar_item(%{"route" => "media", "id" => media_id, "title" => media_title(media_id), "subtitle" => media_subtitle(media_id)}, :pin)

          _other ->
            ChatEditor.set_action_error(socket, socket.assigns.current_tab.id, "Invalid payload for openMedia action", &reload_shell/2)
        end

      :open_settings ->
        socket
        |> clear_chat_action_error()
        |> open_sidebar_item(%{"route" => "settings", "id" => "settings-ai", "title" => "Settings", "subtitle" => "AI"}, :pin)

      :open_chat ->
        chat_id = Map.get(payload, "conversationId") || Map.get(payload, "conversation_id") || socket.assigns.current_tab.id

        socket
        |> clear_chat_action_error()
        |> open_sidebar_item(%{"route" => "chat", "id" => chat_id, "title" => Map.get(payload, "title", "Chat"), "subtitle" => Map.get(payload, "subtitle", "")}, :pin)

      :switch_view ->
        case safe_existing_atom(Map.get(payload, "view")) do
          nil -> ChatEditor.set_action_error(socket, socket.assigns.current_tab.id, "Invalid payload for switchView action", &reload_shell/2)
          view ->
            socket
            |> clear_chat_action_error()
            |> reload_shell(Workbench.click_activity(socket.assigns.workbench, view))
        end

      :toggle_sidebar ->
        socket
        |> clear_chat_action_error()
        |> reload_shell(Workbench.toggle_sidebar(socket.assigns.workbench))

      :toggle_panel ->
        socket
        |> clear_chat_action_error()
        |> reload_shell(Workbench.toggle_panel(socket.assigns.workbench))

      :toggle_assistant_sidebar ->
        socket
        |> clear_chat_action_error()
        |> reload_shell(Workbench.toggle_assistant_sidebar(socket.assigns.workbench))

      :unknown ->
        ChatEditor.set_action_error(socket, socket.assigns.current_tab.id, "Unsupported assistant action", &reload_shell/2)
    end
  end

  defp clear_chat_action_error(%{assigns: %{current_tab: %{type: :chat, id: conversation_id}}} = socket) do
    assign(socket, :chat_editor_action_errors, Map.delete(socket.assigns.chat_editor_action_errors, conversation_id))
  end

  defp clear_chat_action_error(socket), do: socket

  defp decode_chat_surface_payload(nil), do: %{}
  defp decode_chat_surface_payload(""), do: %{}

  defp decode_chat_surface_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_chat_surface_payload(_payload), do: %{}

  defp maybe_put_chat_surface_form_data(payload, socket, surface_id) when is_binary(surface_id) and surface_id != "" do
    form_data = ChatEditor.current_surface_data(socket, surface_id)

    if form_data == %{} do
      payload
    else
      Map.put(payload, "formData", form_data)
    end
  end

  defp maybe_put_chat_surface_form_data(payload, _socket, _surface_id), do: payload

  defp normalize_chat_action(action) do
    action
    |> to_string()
    |> String.replace("_", "")
    |> String.downcase()
    |> case do
      "openpost" -> :open_post
      "openmedia" -> :open_media
      "opensettings" -> :open_settings
      "openchat" -> :open_chat
      "switchview" -> :switch_view
      "setactiveview" -> :switch_view
      "togglesidebar" -> :toggle_sidebar
      "togglepanel" -> :toggle_panel
      "openpanel" -> :toggle_panel
      "toggleassistantsidebar" -> :toggle_assistant_sidebar
      _other -> :unknown
    end
  end

  defp post_title(post_id) do
    case Repo.get(Post, post_id) do
      %Post{} = post -> post.title || post.slug || post.id
      _other -> "Post"
    end
  end

  defp post_subtitle(post_id) do
    case Repo.get(Post, post_id) do
      %Post{} = post -> post.slug || "draft"
      _other -> "draft"
    end
  end

  defp media_title(media_id) do
    case Repo.get(Media, media_id) do
      %Media{} = media -> media.title || media.filename || media.id
      _other -> "Media"
    end
  end

  defp media_subtitle(media_id) do
    case Repo.get(Media, media_id) do
      %Media{} = media -> media.filename || media.mime_type || "media"
      _other -> "media"
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(to_string(value || "0")) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp short_commit_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 7)
  defp short_commit_hash(_hash), do: "-------"

  defp sidebar_route_atom(route) when is_atom(route), do: route
  defp sidebar_route_atom(route) when is_binary(route), do: String.to_existing_atom(route)

  defp tab_id_for_route(route, id) do
    case Registry.editor_route(route) do
      %{singleton: true} -> Atom.to_string(route)
      _other -> id
    end
  end

  defp tab_intent(route, requested_intent) do
    case Registry.editor_route(route) do
      %{singleton: true} -> :pin
      _other -> requested_intent
    end
  end

  defp tab_title(nil, _tab_meta), do: translated("Dashboard")

  defp tab_title(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{title: title} when is_binary(title) and title != "" -> title
      _other -> default_tab_title(tab)
    end
  end

  defp tab_subtitle(nil, _tab_meta), do: translated("dashboard.subtitle")

  defp tab_subtitle(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{subtitle: subtitle} when is_binary(subtitle) and subtitle != "" -> subtitle
      _other -> "Desktop workbench content routed through the Elixir shell."
    end
  end

  defp default_tab_title(%{type: type, id: id}) do
    case Registry.editor_route(type) do
      %{singleton: true} -> ShellData.route_label(type)
      _other -> id
    end
  end

  defp tab_route_label(nil), do: translated("Dashboard")
  defp tab_route_label(%{type: type}), do: ShellData.route_label(type)

  defp editor_toolbar_buttons(nil), do: []

  defp editor_toolbar_buttons(%{type: :post}) do
    [
      %{kind: "ai_suggestions", label: "AI Suggestions", destructive: false},
      %{kind: "insert_link", label: "Insert Link", destructive: false},
      %{kind: "insert_media", label: "Insert Media", destructive: false},
      %{kind: "language_picker", label: "Translate", destructive: false},
      %{kind: "gallery", label: "Gallery", destructive: false}
    ]
  end

  defp editor_toolbar_buttons(%{type: :media}) do
    [
      %{kind: "ai_suggestions", label: "AI Suggestions", destructive: false},
      %{kind: "language_picker", label: "Translate", destructive: false},
      %{kind: "confirm_delete", label: "Delete Media", destructive: true}
    ]
  end

  defp editor_toolbar_buttons(%{type: :tags}) do
    [
      %{kind: "confirm_merge", label: "Merge Tags", destructive: false},
      %{kind: "confirm_delete", label: "Delete Tag", destructive: true}
    ]
  end

  defp editor_toolbar_buttons(_tab), do: []

  defp tab_icon_id(nil), do: "posts"
  defp tab_icon_id(%{type: :post}), do: "posts"
  defp tab_icon_id(%{type: :git_diff}), do: "git"
  defp tab_icon_id(%{type: :style}), do: "settings"
  defp tab_icon_id(%{type: type}), do: Atom.to_string(type)

  defp assistant_turn(prompt, socket) do
    [
      %{role: "user", content: prompt},
      %{role: "assistant", content: assistant_reply(socket)}
    ]
  end

  defp assistant_reply(socket) do
    if socket.assigns.offline_mode do
      ShellData.translate("Automatic AI actions stay gated by airplane mode.", %{}, socket.assigns.page_language)
    else
      ShellData.translate(
        "The assistant sidebar chat surface is ready, but model execution is not connected yet.",
        %{},
        socket.assigns.page_language
      )
    end
  end

  defp assistant_project_name(nil), do: translated("Projects")
  defp assistant_project_name(project), do: project.name

  defp assistant_message_label("assistant"), do: translated("Assistant")
  defp assistant_message_label("user"), do: translated("You")
  defp assistant_message_label(_role), do: translated("Assistant")

  defp assistant_message_testid(role), do: "assistant-message-#{role}"

  defp update_shell_overlay(socket, updater) do
    case socket.assigns[:shell_overlay] do
      nil -> socket
      overlay -> assign(socket, :shell_overlay, updater.(overlay))
    end
  end

  defp close_overlay_with_output(socket, title, details) do
    socket
    |> append_output_entry(title, translated("Command completed"), details)
    |> assign(:shell_overlay, nil)
  end

end
