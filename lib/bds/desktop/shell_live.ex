defmodule BDS.Desktop.ShellLive do
  @moduledoc false

  use Phoenix.LiveView

  import Phoenix.HTML

  alias BDS.Desktop.{FolderPicker, Overlay, ShellCommands, ShellData}
  alias BDS.Desktop.ShellLive.OverlayComponents, as: ShellOverlayComponents
  alias BDS.Desktop.ShellLive.PostEditor
  alias BDS.Desktop.MenuBar, as: DesktopMenuBar
  alias BDS.{Git, Posts}
  alias BDS.Media.Media
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
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
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, :refresh_task_status)
    end

    workbench = Workbench.new()

    {:ok,
     socket
     |> assign(:page_title, ShellData.title())
     |> assign(:page_language, ShellData.ui_language())
      |> assign(:client_shortcuts, Commands.client_shortcuts())
     |> assign(:offline_mode, true)
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
        |> assign(:post_editor_modes, %{})
        |> assign(:post_editor_expanded, %{})
        |> assign(:post_editor_save_states, %{})
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
      put_sidebar_filter_panel_state(socket, fn state ->
        if state.visible do
          %{state | visible: false}
        else
          %{default_sidebar_filter_panel_state() | visible: true}
        end
      end)

    {:noreply,
     socket
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_archive", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filter_panel_state(fn state -> %{state | archive_collapsed: not state.archive_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_tags", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filter_panel_state(fn state -> %{state | tags_collapsed: not state.tags_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_categories", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filter_panel_state(fn state -> %{state | categories_collapsed: not state.categories_collapsed} end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("update_sidebar_search", %{"sidebar_filters" => params}, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> Map.put(filters, :search, normalize_filter_string(Map.get(params, "search"))) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_search", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> Map.put(filters, :search, nil) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_tags", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> Map.put(filters, :tags, []) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_categories", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> Map.put(filters, :categories, []) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_tag", %{"tag" => tag}, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> toggle_filter_value(filters, :tags, tag) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_sidebar_category", %{"category" => category}, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters -> toggle_filter_value(filters, :categories, category) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("select_sidebar_year", %{"year" => year}, socket) do
    parsed_year = parse_optional_integer(year)

    {:noreply,
     socket
     |> put_sidebar_filter_panel_state(fn state ->
       %{state |
         archive_collapsed: false,
         expanded_year: if(state.expanded_year == parsed_year, do: nil, else: parsed_year)
       }
     end)
     |> put_sidebar_filters(fn filters ->
       filters
       |> Map.put(:year, parsed_year)
       |> Map.put(:month, nil)
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("select_sidebar_month", %{"year" => year, "month" => month}, socket) do
    {:noreply,
     socket
     |> put_sidebar_filter_panel_state(fn state ->
       %{state | archive_collapsed: false, expanded_year: parse_optional_integer(year)}
     end)
     |> put_sidebar_filters(fn filters ->
       filters
       |> Map.put(:year, parse_optional_integer(year))
       |> Map.put(:month, parse_optional_integer(month))
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_month", _params, socket) do
    {:noreply,
     socket
      |> put_sidebar_filter_panel_state(fn state -> %{state | archive_collapsed: false} end)
     |> put_sidebar_filters(fn filters -> filters |> Map.put(:year, nil) |> Map.put(:month, nil) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("clear_sidebar_filters", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters ->
       filters
       |> Map.put(:search, nil)
       |> Map.put(:year, nil)
       |> Map.put(:month, nil)
       |> Map.put(:tags, [])
       |> Map.put(:categories, [])
       |> Map.put(:display_limit, sidebar_page_size(socket.assigns.sidebar_data))
     end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("load_more_sidebar", _params, socket) do
    {:noreply,
     socket
     |> put_sidebar_filters(fn filters ->
       Map.update(filters, :display_limit, sidebar_page_size(socket.assigns.sidebar_data), &(&1 + sidebar_page_size(socket.assigns.sidebar_data)))
     end)
     |> reload_shell(socket.assigns.workbench)}
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

  def handle_event("toggle_offline_mode", _params, socket) do
    socket = assign(socket, :offline_mode, not socket.assigns.offline_mode)
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
    {:noreply, update_post_editor(socket, params)}
  end

  def handle_event("save_post_editor", %{"id" => post_id}, socket) do
    {:noreply, persist_post_editor(socket, post_id, :save)}
  end

  def handle_event("publish_post_editor", %{"id" => post_id}, socket) do
    {:noreply, persist_post_editor(socket, post_id, :publish)}
  end

  def handle_event("discard_post_editor", %{"id" => post_id}, socket) do
    {:noreply, discard_post_editor(socket, post_id)}
  end

  def handle_event("delete_post_editor", %{"id" => post_id}, socket) do
    {:noreply, delete_post_editor(socket, post_id)}
  end

  def handle_event("set_post_editor_mode", %{"id" => post_id, "mode" => mode}, socket) do
    {:noreply,
     socket
      |> assign(:post_editor_modes, Map.put(socket.assigns.post_editor_modes, post_id, PostEditor.normalize_mode(mode)))
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_post_metadata", %{"id" => post_id}, socket) do
    {:noreply,
     socket
     |> update_post_editor_expanded(post_id, fn expanded -> Map.update!(expanded, :metadata, &not &1) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("toggle_post_excerpt", %{"id" => post_id}, socket) do
    {:noreply,
     socket
     |> update_post_editor_expanded(post_id, fn expanded -> Map.update!(expanded, :excerpt, &not &1) end)
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("select_post_editor_language", %{"id" => post_id, "language" => language}, socket) do
    {:noreply,
     socket
      |> assign(:post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, PostEditor.normalize_language(language, language)))
     |> reload_shell(socket.assigns.workbench)}
  end

  def handle_event("open_overlay", %{"kind" => kind}, socket) do
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

    socket =
      case overlay do
        %{kind: :insert_link} ->
          case Overlay.insert_link_result(overlay, id) do
            nil -> socket
            result -> close_overlay_with_output(socket, overlay.title, ShellOverlayComponents.markdown_link(result.title, result.canonical_url))
          end

        %{kind: :insert_media} ->
          case Overlay.insert_media_result(overlay, id) do
            nil -> socket
            result ->
              syntax =
                if result.is_image do
                  "![#{result.title}](bds-media://#{result.media_id})"
                else
                  "[#{result.original_name}](bds-media://#{result.media_id})"
                end

              close_overlay_with_output(socket, overlay.title, syntax)
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_insert_external", _params, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :insert_link} = overlay ->
          details =
            case {overlay.external_url, String.trim(overlay.external_text || "")} do
              {"", _text} -> nil
              {url, ""} -> url
              {url, text} -> ShellOverlayComponents.markdown_link(text, url)
            end

          if details do
            close_overlay_with_output(socket, overlay.title, details)
          else
            socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_select_language", %{"code" => code}, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :language_picker, title: title} -> close_overlay_with_output(socket, title, code)
        _other -> socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_confirm", _params, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :ai_suggestions, title: title} = overlay ->
          selected = Overlay.selected_ai_fields(overlay)
          details = Enum.map_join(selected, ", ", & &1.label)
          close_overlay_with_output(socket, title, details)

        %{kind: :confirm_delete, title: title, entity_name: entity_name} ->
          close_overlay_with_output(socket, title, entity_name)

        %{kind: :confirm_dialog, title: title, message: message} ->
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
  def handle_info(:refresh_task_status, socket) do
    task_status = BDS.Tasks.status_snapshot()

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
    sidebar_data = ShellData.sidebar_view(projects.active_project_id, active_view_id, current_sidebar_filters(socket, active_view_id))
    sidebar_data = merge_sidebar_ui_state(socket, active_view_id, sidebar_data)
    task_status = BDS.Tasks.status_snapshot()
    activity_buttons = Workbench.activity_buttons(workbench, git_badge_count)
    page_language = socket.assigns[:page_language] || ShellData.ui_language()
    offline_mode = Map.get(socket.assigns, :offline_mode, true)

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
  end

  defp render_sidebar_filters(assigns) do
    filters = Map.get(assigns.sidebar_data, :filters)

    if is_map(filters) and Map.get(filters, :enabled) do
      selected = Map.get(filters, :selected, %{})

      assigns =
        assigns
        |> assign(:sidebar_filters_config, filters)
        |> assign(:selected_filters, selected)
        |> assign(:filter_panel_visible, Map.get(filters, :filter_panel_visible, false))
        |> assign(:archive_collapsed, Map.get(filters, :archive_collapsed, true))
        |> assign(:tags_collapsed, Map.get(filters, :tags_collapsed, true))
        |> assign(:categories_collapsed, Map.get(filters, :categories_collapsed, true))
        |> assign(:expanded_year, Map.get(filters, :expanded_year))
        |> assign(:year_groups, group_year_month_counts(Map.get(filters, :year_month_counts, [])))

      ~H"""
      <form class="search-box" data-testid="sidebar-search-form" phx-change="update_sidebar_search" phx-submit="update_sidebar_search">
        <input
          type="text"
          name="sidebar_filters[search]"
          value={Map.get(@selected_filters, :search) || ""}
          placeholder={translated(@sidebar_filters_config.search_placeholder)}
        />
        <button type="submit" title={translated("sidebar.search")}>
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M15.7 14.3l-4.2-4.2c-.2-.2-.5-.3-.8-.3.9-1.1 1.5-2.5 1.5-4C12.2 2.6 9.6 0 6.4 0S.6 2.6.6 5.8s2.6 5.8 5.8 5.8c1.5 0 2.9-.5 4-1.4 0 .3.1.6.3.8l4.2 4.2c.2.2.5.3.7.3s.5-.1.7-.3c.4-.4.4-1 0-1.4zm-9.3-4c-2.5 0-4.5-2-4.5-4.5s2-4.5 4.5-4.5 4.5 2 4.5 4.5-2 4.5-4.5 4.5z"/>
          </svg>
        </button>
        <%= if Map.get(@selected_filters, :search) do %>
          <button class="clear-search" data-testid="sidebar-clear-search" type="button" phx-click="clear_sidebar_search">×</button>
        <% end %>
      </form>

      <%= if Map.get(@sidebar_filters_config, :has_active_filters) do %>
        <div class="filter-status">
          <span>
            <%= translated(@sidebar_filters_config.results_label) %>: <%= @sidebar_filters_config.loaded_count %>/<%= @sidebar_filters_config.total_count %>
          </span>
          <button data-testid="sidebar-clear-filters" type="button" phx-click="clear_sidebar_filters">
            <%= translated(@sidebar_filters_config.clear_filters_label) %>
          </button>
        </div>
      <% end %>

      <%= if @filter_panel_visible do %>
        <%= if Enum.any?(@year_groups) do %>
          <div class="calendar-view">
            <div
              class={[
                "calendar-header",
                "collapsible-header",
                if(@archive_collapsed, do: "collapsed", else: "expanded")
              ]}
              data-testid="sidebar-filter-archive-header"
              phx-click="toggle_sidebar_archive"
            >
              <span class="collapse-icon"><%= if @archive_collapsed, do: "▶", else: "▼" %></span>
              <span><%= translated(@sidebar_filters_config.archive_label) %></span>
              <%= if Map.get(@selected_filters, :year) do %>
                <button class="clear-filter" type="button" phx-click="clear_sidebar_month" phx-stop-propagation>✕</button>
              <% end %>
            </div>
            <%= unless @archive_collapsed do %>
              <div class="calendar-years">
                <%= for year_group <- @year_groups do %>
                  <div class="calendar-year">
                    <div
                      class={[
                        "calendar-year-header",
                        if(Map.get(@selected_filters, :year) == year_group.year and is_nil(Map.get(@selected_filters, :month)), do: "selected")
                      ]}
                      phx-click="select_sidebar_year"
                      phx-value-year={year_group.year}
                    >
                      <span class="expand-icon"><%= if @expanded_year == year_group.year, do: "▼", else: "▶" %></span>
                      <span class="year-label"><%= year_group.year %></span>
                      <span class="year-count"><%= year_group.count %></span>
                    </div>
                    <%= if @expanded_year == year_group.year do %>
                      <div class="calendar-months">
                        <%= for month_entry <- year_group.months do %>
                          <button
                            class={[
                              "calendar-month",
                              if(Map.get(@selected_filters, :year) == year_group.year and Map.get(@selected_filters, :month) == month_entry.month, do: "selected")
                            ]}
                            data-testid="sidebar-filter-month"
                            type="button"
                            phx-click="select_sidebar_month"
                            phx-value-year={year_group.year}
                            phx-value-month={month_entry.month}
                          >
                            <span class="month-label"><%= ShellData.format_dashboard_month(year_group.year, month_entry.month) %></span>
                            <span class="month-count"><%= month_entry.count %></span>
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="filter-panel">
          <%= if Enum.any?(Map.get(@sidebar_filters_config, :available_tags, [])) do %>
            <section class="filter-section">
              <div
                class={[
                  "filter-header",
                  "collapsible-header",
                  if(@tags_collapsed, do: "collapsed", else: "expanded")
                ]}
                data-testid="sidebar-filter-tags-header"
                phx-click="toggle_sidebar_tags"
              >
                <span class="collapse-icon"><%= if @tags_collapsed, do: "▶", else: "▼" %></span>
                <span><%= translated(@sidebar_filters_config.tags_label) %></span>
                <%= if Enum.any?(Map.get(@selected_filters, :tags, [])) do %>
                  <button class="clear-filter" type="button" phx-click="clear_sidebar_tags" phx-stop-propagation title={translated(@sidebar_filters_config.clear_tags_label)}>✕</button>
                <% end %>
              </div>
              <%= unless @tags_collapsed do %>
                <div class="filter-chips">
                  <%= for tag <- Map.get(@sidebar_filters_config, :available_tags, []) do %>
                    <button
                      class={[
                        "filter-chip",
                        if(tag in Map.get(@selected_filters, :tags, []), do: "active"),
                        if(sidebar_filter_tag_color(@sidebar_filters_config, tag), do: "has-color")
                      ]}
                      style={sidebar_filter_chip_style(@sidebar_filters_config, tag)}
                      data-testid="sidebar-filter-tag"
                      data-filter-tag={tag}
                      type="button"
                      phx-click="toggle_sidebar_tag"
                      phx-value-tag={tag}
                    >
                      <%= tag %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </section>
          <% end %>

          <%= if Enum.any?(Map.get(@sidebar_filters_config, :available_categories, [])) do %>
            <section class="filter-section">
              <div
                class={[
                  "filter-header",
                  "collapsible-header",
                  if(@categories_collapsed, do: "collapsed", else: "expanded")
                ]}
                data-testid="sidebar-filter-categories-header"
                phx-click="toggle_sidebar_categories"
              >
                <span class="collapse-icon"><%= if @categories_collapsed, do: "▶", else: "▼" %></span>
                <span><%= translated(@sidebar_filters_config.categories_label) %></span>
                <%= if Enum.any?(Map.get(@selected_filters, :categories, [])) do %>
                  <button class="clear-filter" type="button" phx-click="clear_sidebar_categories" phx-stop-propagation title={translated(@sidebar_filters_config.clear_categories_label)}>✕</button>
                <% end %>
              </div>
              <%= unless @categories_collapsed do %>
                <div class="filter-chips">
                  <%= for category <- Map.get(@sidebar_filters_config, :available_categories, []) do %>
                    <button
                      class={[
                        "filter-chip",
                        if(category in Map.get(@selected_filters, :categories, []), do: "active")
                      ]}
                      data-testid="sidebar-filter-category"
                      data-filter-category={category}
                      type="button"
                      phx-click="toggle_sidebar_category"
                      phx-value-category={category}
                    >
                      <%= category %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </section>
          <% end %>
        </div>
      <% end %>

      """
    else
      ~H"""
      """
    end
  end

  defp render_sidebar_load_more(assigns) do
    filters = Map.get(assigns.sidebar_data, :filters, %{})

    if Map.get(filters, :has_more) do
      ~H"""
      <div class="sidebar-load-more">
        <button class="load-more-button" data-testid="sidebar-load-more" type="button" phx-click="load_more_sidebar">
          <%= translated("Load more") %>
        </button>
      </div>
      """
    else
      ~H"""
      """
    end
  end

  defp render_sidebar_body(assigns) do
    case assigns.sidebar_data.layout do
      "post_list" -> render_post_sidebar(assigns)
      "media_grid" -> render_media_sidebar(assigns)
      "entity_list" -> render_entity_sidebar(assigns)
      "nav_list" -> render_nav_sidebar(assigns)
      _other -> render_default_sidebar(assigns)
    end
  end

  defp render_post_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-title">
          <span class={"section-icon status-#{Map.get(section, :status, "draft")}"}>●</span>
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
          <span class="sidebar-section-count"><%= Map.get(section, :count, length(Map.get(section, :items, []))) %></span>
        </div>
        <div class="sidebar-list">
          <%= for item <- Map.get(section, :items, []) do %>
            <button
              class={["sidebar-item", "sidebar-post-item", "post-type-post", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
              data-testid="sidebar-open-item"
              data-route={item.route}
              data-item-id={item.id}
              data-open-title={item.title}
              data-open-subtitle={format_sidebar_timestamp(item.meta_timestamp)}
              type="button"
              phx-click="open_sidebar_item"
              phx-value-route={item.route}
              phx-value-id={item.id}
              phx-value-title={item.title}
              phx-value-subtitle={format_sidebar_timestamp(item.meta_timestamp)}
            >
              <span class="post-type-icon" title="post">●</span>
              <span class="sidebar-item-content">
                <span class="sidebar-item-title-row">
                  <span class="sidebar-item-title"><%= item.title %></span>
                </span>
                <span class="sidebar-item-meta"><%= format_sidebar_timestamp(item.meta_timestamp) %></span>
              </span>
            </button>
          <% end %>
        </div>
      </section>
    <% end %>
    <%= if Enum.empty?(Map.get(@sidebar_data, :sections, [])) do %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_media_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class="sidebar-list media-grid">
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <button
            class={["media-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
            data-testid="sidebar-open-item"
            data-route={item.route}
            data-item-id={item.id}
            data-open-title={item.title}
            data-open-subtitle={item.meta}
            type="button"
            title={item.title}
            phx-click="open_sidebar_item"
            phx-value-route={item.route}
            phx-value-id={item.id}
            phx-value-title={item.title}
            phx-value-subtitle={item.meta}
          >
            <span class={media_thumbnail_class(item)}>
              <%= if image_media?(item) do %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
                <img class="media-thumbnail-image" src={"/media-thumbnail/#{item.id}"} alt="" loading="lazy" decoding="async" />
              <% else %>
                <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
              <% end %>
            </span>
            <span class="media-item-info">
              <span class="media-item-name"><%= item.title %></span>
              <span class="media-item-size"><%= item.meta %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_entity_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class="settings-nav-list">
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <button
            class={["chat-list-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "active")]}
            data-testid="sidebar-open-item"
            data-route={item.route}
            data-item-id={item.id}
            data-open-title={item.title}
            data-open-subtitle={translated(item.meta || "")}
            type="button"
            phx-click="open_sidebar_item"
            phx-value-route={item.route}
            phx-value-id={item.id}
            phx-value-title={item.title}
            phx-value-subtitle={translated(item.meta || "")}
          >
            <span class="chat-item-content">
              <span class="chat-item-title"><%= item.title %></span>
              <span class="chat-item-date"><%= translated(item.meta || "") %></span>
            </span>
          </button>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= translated(Map.get(@sidebar_data, :empty_message, "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_nav_sidebar(assigns) do
    ~H"""
    <div class="settings-nav-list">
      <%= for item <- Map.get(@sidebar_data, :items, []) do %>
        <button
          class="settings-nav-entry"
          data-testid="sidebar-open-item"
          data-route={item.route}
          data-item-id={item.id}
          data-open-title={translated(item.title)}
          data-open-subtitle={translated(Map.get(@sidebar_data, :subtitle, ""))}
          type="button"
          phx-click="open_sidebar_item"
          phx-value-route={item.route}
          phx-value-id={item.id}
          phx-value-title={translated(item.title)}
          phx-value-subtitle={translated(Map.get(@sidebar_data, :subtitle, ""))}
        >
          <span class="settings-nav-entry-icon"><%= Map.get(item, :icon, "") %></span>
          <span><%= translated(item.title) %></span>
        </button>
      <% end %>
    </div>
    """
  end

  defp render_default_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-header">
          <span data-testid="sidebar-section-title"><%= translated(section.title) %></span>
        </div>
        <div class="sidebar-section-items">
          <%= for item <- Map.get(section, :items, []) do %>
            <div class="sidebar-list-item"><%= item.title || "" %></div>
          <% end %>
        </div>
      </section>
    <% end %>
    """
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
              <span class={"task-status task-status-#{task.status}"}><%= task.status |> to_string() |> String.capitalize() %></span>
            </div>
            <span><%= task.message || task.group_name || "" %></span>
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

  defp format_sidebar_timestamp(nil), do: ""

  defp format_sidebar_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%x")
  end

  defp image_media?(item), do: String.starts_with?(to_string(item.mime_type || ""), "image/")

  defp media_thumbnail_class(item) do
    if image_media?(item), do: "media-thumbnail has-image", else: "media-thumbnail"
  end

  defp current_tab(%{active_tab: nil}), do: nil

  defp current_tab(%{tabs: tabs, active_tab: {type, id}}) do
    Enum.find(tabs, &(&1.type == type and &1.id == id))
  end

  defp assign_post_editor(socket) do
    assigns = Map.put(socket.assigns, :project_metadata, ShellOverlayComponents.project_metadata(socket.assigns.projects.active_project_id))
    assign(socket, :post_editor, PostEditor.build(assigns))
  end

  defp update_post_editor(socket, params) do
    case socket.assigns.current_tab do
      %{type: :post, id: post_id} ->
        case Repo.get(Post, post_id) do
          nil ->
            socket

          %Post{} = post ->
            metadata = ShellOverlayComponents.project_metadata(post.project_id)
            canonical_language = PostEditor.normalize_language(post.language, metadata.main_language || "en")
            current_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
            requested_language = PostEditor.normalize_language(Map.get(params, "language"), current_language)

            next_language =
              if current_language == canonical_language do
                requested_language
              else
                current_language
              end

            draft = PostEditor.normalize_params(params, current_language, next_language)
            workbench = Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)

            socket
            |> assign(:workbench, workbench)
            |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, next_language, draft))
            |> assign(:post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, next_language))
            |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :dirty))
            |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: draft["title"], subtitle: Atom.to_string(post.status || :draft)}))
            |> maybe_drop_old_language_draft(post_id, current_language, next_language)
            |> reload_shell(workbench)
        end

      _other ->
        socket
    end
  end

  defp maybe_drop_old_language_draft(socket, _post_id, current_language, next_language) when current_language == next_language,
    do: socket

  defp maybe_drop_old_language_draft(socket, post_id, current_language, _next_language) do
    assign(socket, :post_editor_drafts, delete_nested_map(socket.assigns.post_editor_drafts, post_id, current_language))
  end

  defp persist_post_editor(socket, post_id, action) do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = ShellOverlayComponents.project_metadata(post.project_id)
        canonical_language = PostEditor.normalize_language(post.language, metadata.main_language || "en")
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
        draft = PostEditor.current_draft(socket.assigns, post, metadata, active_language)

        result = PostEditor.persist(post, draft, active_language, metadata, action)

        case result do
          {:ok, record} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :post, post_id)
            normalized_form = PostEditor.persisted_form(Repo.get!(Post, post_id), metadata, active_language)

            socket
            |> assign(:workbench, workbench)
            |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, active_language, normalized_form))
            |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, PostEditor.save_state_for_action(action)))
            |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: PostEditor.record_title(record, Repo.get!(Post, post_id)), subtitle: Atom.to_string(PostEditor.record_status(record))}))
            |> reload_shell(workbench)

          {:error, reason} ->
            socket
            |> append_output_entry(translated("Post"), inspect(reason), nil, "error")
            |> reload_shell(socket.assigns.workbench)
        end
    end
  end

  defp discard_post_editor(socket, post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = ShellOverlayComponents.project_metadata(post.project_id)
        canonical_language = PostEditor.normalize_language(post.language, metadata.main_language || "en")
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
        restored_result = PostEditor.discard(post, active_language, metadata)

        case restored_result do
          {:ok, restored_post} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :post, post_id)

            socket
            |> assign(:workbench, workbench)
            |> assign(:post_editor_drafts, delete_nested_map(socket.assigns.post_editor_drafts, post_id, active_language))
            |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :discarded))
            |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: restored_post.title || restored_post.slug || restored_post.id, subtitle: Atom.to_string(restored_post.status || :draft)}))
            |> reload_shell(workbench)

          {:error, reason} ->
            socket
            |> append_output_entry(translated("Post"), inspect(reason), nil, "error")
            |> reload_shell(socket.assigns.workbench)
        end
    end
  end

  defp delete_post_editor(socket, post_id) do
    case Posts.delete_post(post_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :post, post_id)

        socket
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:post, post_id}))
        |> assign(:post_editor_drafts, Map.delete(socket.assigns.post_editor_drafts, post_id))
        |> assign(:post_editor_active_languages, Map.delete(socket.assigns.post_editor_active_languages, post_id))
        |> assign(:post_editor_modes, Map.delete(socket.assigns.post_editor_modes, post_id))
        |> assign(:post_editor_expanded, Map.delete(socket.assigns.post_editor_expanded, post_id))
        |> assign(:post_editor_save_states, Map.delete(socket.assigns.post_editor_save_states, post_id))
        |> reload_shell(workbench)

      {:error, reason} ->
        socket
        |> append_output_entry(translated("Post"), inspect(reason), nil, "error")
        |> reload_shell(socket.assigns.workbench)
    end
  end

  defp update_post_editor_expanded(socket, post_id, updater) do
    expanded =
      socket.assigns.post_editor_expanded
      |> Map.get(post_id, %{metadata: false, excerpt: false})
      |> Map.put_new(:metadata, false)
      |> Map.put_new(:excerpt, false)
      |> updater.()

    assign(socket, :post_editor_expanded, Map.put(socket.assigns.post_editor_expanded, post_id, expanded))
  end

  defp put_nested_map(map, key, nested_key, value) do
    Map.update(map, key, %{nested_key => value}, &Map.put(&1, nested_key, value))
  end

  defp delete_nested_map(map, key, nested_key) do
    case Map.get(map, key) do
      nil -> map
      nested ->
        case Map.delete(nested, nested_key) do
          emptied when map_size(emptied) == 0 -> Map.delete(map, key)
          remaining -> Map.put(map, key, remaining)
        end
    end
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

  defp open_sidebar_item(socket, params, intent) do
    route_atom = sidebar_route_atom(Map.fetch!(params, "route"))
    tab_id = tab_id_for_route(route_atom, Map.fetch!(params, "id"))

    workbench =
      Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, tab_intent(route_atom, intent))

    tab_meta =
      Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{
        title: Map.get(params, "title", ""),
        subtitle: Map.get(params, "subtitle", "")
      })

    socket
    |> assign(:tab_meta, tab_meta)
    |> reload_shell(workbench)
  end

  defp merge_sidebar_ui_state(socket, view_id, sidebar_data) do
    filters = Map.get(sidebar_data, :filters)

    if is_map(filters) and Map.get(filters, :enabled) do
      panel_state = sidebar_filter_panel_state(socket, view_id)

      Map.put(sidebar_data, :filters, Map.merge(filters, %{
        filter_panel_visible: panel_state.visible,
        archive_collapsed: panel_state.archive_collapsed,
        tags_collapsed: panel_state.tags_collapsed,
        categories_collapsed: panel_state.categories_collapsed,
        expanded_year: panel_state.expanded_year
      }))
    else
      sidebar_data
    end
  end

  defp sidebar_filter_panel_state(socket, view_id) do
    default_state = default_sidebar_filter_panel_state()

    case Map.get(socket.assigns.sidebar_filter_panels, view_id) do
      state when is_map(state) -> Map.merge(default_state, state)
      visible when is_boolean(visible) -> Map.put(default_state, :visible, visible)
      _other -> default_state
    end
  end

  defp put_sidebar_filter_panel_state(socket, updater) do
    view_id = Atom.to_string(socket.assigns.workbench.active_view)
    state = socket |> sidebar_filter_panel_state(view_id) |> updater.()
    assign(socket, :sidebar_filter_panels, Map.put(socket.assigns.sidebar_filter_panels, view_id, state))
  end

  defp default_sidebar_filter_panel_state do
    %{
      visible: false,
      archive_collapsed: true,
      tags_collapsed: true,
      categories_collapsed: true,
      expanded_year: nil
    }
  end

  defp current_sidebar_filters(socket, view_id) do
    socket.assigns.sidebar_filters_by_view
    |> Map.get(view_id, %{})
    |> normalize_sidebar_filters(socket.assigns[:sidebar_data])
  end

  defp normalize_sidebar_filters(filters, sidebar_data) do
    max_items = sidebar_page_size(sidebar_data)

    %{
      search: normalize_filter_string(Map.get(filters, :search)),
      year: Map.get(filters, :year),
      month: Map.get(filters, :month),
      tags: Map.get(filters, :tags, []),
      categories: Map.get(filters, :categories, []),
      display_limit: max(Map.get(filters, :display_limit, max_items) || max_items, max_items)
    }
  end

  defp put_sidebar_filters(socket, updater) do
    view_id = Atom.to_string(socket.assigns.workbench.active_view)
    filters = current_sidebar_filters(socket, view_id) |> updater.() |> normalize_sidebar_filters(socket.assigns.sidebar_data)
    assign(socket, :sidebar_filters_by_view, Map.put(socket.assigns.sidebar_filters_by_view, view_id, filters))
  end

  defp toggle_filter_value(filters, key, value) do
    values = Map.get(filters, key, [])

    next_values =
      if value in values do
        List.delete(values, value)
      else
        values ++ [value]
      end

    Map.put(filters, key, next_values)
  end

  defp group_year_month_counts(entries) do
    entries
    |> Enum.group_by(& &1.year)
    |> Enum.map(fn {year, months} ->
      %{
        year: year,
        count: Enum.reduce(months, 0, fn entry, acc -> acc + (entry.count || 0) end),
        months: Enum.sort_by(months, &-&1.month)
      }
    end)
    |> Enum.sort_by(&-&1.year)
  end

  defp sidebar_filter_tag_color(filters_config, tag) do
    filters_config
    |> Map.get(:available_tag_colors, %{})
    |> Map.get(tag)
    |> normalize_sidebar_filter_color()
  end

  defp sidebar_filter_chip_style(filters_config, tag) do
    case sidebar_filter_tag_color(filters_config, tag) do
      nil -> nil
      color -> "background-color: #{color}; color: #{sidebar_filter_contrast_color(color)}; border-color: #{color};"
    end
  end

  defp normalize_sidebar_filter_color(nil), do: nil
  defp normalize_sidebar_filter_color(""), do: nil

  defp normalize_sidebar_filter_color("#" <> rest = color) when byte_size(rest) == 6 do
    if String.match?(rest, ~r/\A[0-9a-fA-F]{6}\z/), do: color, else: nil
  end

  defp normalize_sidebar_filter_color(_color), do: nil

  defp sidebar_filter_contrast_color("#" <> rgb) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = rgb
    {red, _} = Integer.parse(r, 16)
    {green, _} = Integer.parse(g, 16)
    {blue, _} = Integer.parse(b, 16)
    luminance = (red * 299 + green * 587 + blue * 114) / 1000
    if luminance > 150, do: "#1e1e1e", else: "#ffffff"
  end

  defp sidebar_filter_contrast_color(_color), do: "#ffffff"

  defp sidebar_filters_enabled?(sidebar_data) do
    sidebar_data
    |> Map.get(:filters)
    |> then(&(is_map(&1) and Map.get(&1, :enabled, false)))
  end

  defp sidebar_filters_visible?(sidebar_data) do
    sidebar_data
    |> Map.get(:filters, %{})
    |> Map.get(:filter_panel_visible, false)
  end

  defp normalize_filter_string(nil), do: nil

  defp normalize_filter_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_optional_integer(nil), do: nil
  defp parse_optional_integer(value) when is_integer(value), do: value

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp sidebar_page_size(nil), do: 500

  defp sidebar_page_size(sidebar_data) do
    sidebar_data
    |> Map.get(:filters, %{})
    |> Map.get(:max_items, 500)
  end

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

  defp apply_shell_command(socket, action) do
    case ShellCommands.execute(action) do
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
    |> append_output_entry(title, message)
    |> reload_shell(workbench)
  end

  defp apply_shell_command_result(socket, %{kind: "output", title: title, message: message} = result) do
    socket
    |> append_output_entry(title, message, Map.get(result, :details), Map.get(result, :level, "info"))
  end

  defp apply_shell_command_result(socket, %{kind: "open_url", title: title, message: message, url: url}) do
    append_output_entry(socket, title, message, url)
  end

  defp apply_shell_command_result(socket, %{kind: "open_editor", route: route, title: title, subtitle: subtitle}) do
    route_atom = String.to_existing_atom(route)
    tab_id = tab_id_for_route(route_atom, route)
    workbench = Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, :pin)
    tab_meta = Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{title: title, subtitle: subtitle})

    socket
    |> assign(:tab_meta, tab_meta)
    |> reload_shell(workbench)
  end

  defp apply_shell_command_result(socket, _result), do: socket

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

  defp sidebar_item_selected?(workbench, route, id) do
    route_atom = sidebar_route_atom(route)
    workbench.active_tab == {route_atom, tab_id_for_route(route_atom, id)}
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

  defp media_thumbnail_glyph(mime_type) do
    case String.split(to_string(mime_type || ""), "/", parts: 2) do
      ["image", _rest] -> "IMG"
      ["video", _rest] -> "VID"
      ["audio", _rest] -> "AUD"
      ["application", _rest] -> "DOC"
      _other -> "FILE"
    end
  end
end
