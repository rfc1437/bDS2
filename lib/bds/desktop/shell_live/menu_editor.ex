defmodule BDS.Desktop.ShellLive.MenuEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.ShellData
  alias BDS.{Menu, Metadata, Repo}
  alias BDS.Posts.Post

  embed_templates "menu_editor_html/*"

  @home_item_id "menu-home"

  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :menu_editor, id: tab_id} ->
        state = ensure_state(socket.assigns)
        menu_editor = build(socket.assigns, state)

        socket
        |> assign(:menu_editor_state, state)
        |> assign(:menu_editor, menu_editor)
        |> assign(
          :tab_meta,
          Map.put(socket.assigns.tab_meta, {:menu_editor, tab_id}, %{
            title: translated("menuEditor.tabTitle"),
            subtitle: translated("menuEditor.description")
          })
        )

      _other ->
        assign(socket, :menu_editor, nil)
    end
  end

  def select_item(socket, item_id, reload) do
    socket
    |> update_state(fn state -> %{state | selected_id: item_id} end)
    |> reload.(socket.assigns.workbench)
  end

  def change_entry(socket, params, reload) do
    query = Map.get(params, "query", "")

    socket
    |> update_state(fn state -> put_in(state, [:draft, :query], query) end)
    |> reload.(socket.assigns.workbench)
  end

  def submit_entry(socket, reload) do
    case current_draft(socket.assigns) do
      %{type: :page} ->
        socket
        |> update_state(&finalize_submenu_draft/1)
        |> reload.(socket.assigns.workbench)

      %{type: :category} ->
        socket
        |> confirm_category_draft()
        |> reload.(socket.assigns.workbench)

      _other ->
        reload.(socket, socket.assigns.workbench)
    end
  end

  def cancel_entry(socket, reload) do
    socket
    |> update_state(&cancel_draft/1)
    |> reload.(socket.assigns.workbench)
  end

  def select_page(socket, post_id, reload) do
    case page_post(socket.assigns.projects.active_project_id, post_id) do
      nil -> reload.(socket, socket.assigns.workbench)

      post ->
        socket
        |> update_state(&assign_page_to_draft(&1, post))
        |> reload.(socket.assigns.workbench)
    end
  end

  def select_category(socket, name, reload) do
    project_id = socket.assigns.projects.active_project_id

    case Enum.find(category_options(project_id), &(&1.name == name)) do
      nil -> reload.(socket, socket.assigns.workbench)

      category ->
        socket
        |> update_state(&assign_category_to_draft(&1, category))
        |> reload.(socket.assigns.workbench)
    end
  end

  def toolbar_action(socket, action, reload, append_output) do
    case action do
      "add-entry" ->
        socket
        |> update_state(&start_page_draft/1)
        |> reload.(socket.assigns.workbench)

      "add-category-archive" ->
        socket
        |> update_state(&start_category_draft/1)
        |> reload.(socket.assigns.workbench)

      "save" ->
        save(socket, reload, append_output)

      "move-up" ->
        socket
        |> update_state(&move_selected(&1, :up))
        |> reload.(socket.assigns.workbench)

      "move-down" ->
        socket
        |> update_state(&move_selected(&1, :down))
        |> reload.(socket.assigns.workbench)

      "indent" ->
        socket
        |> update_state(&indent_selected/1)
        |> reload.(socket.assigns.workbench)

      "unindent" ->
        socket
        |> update_state(&unindent_selected/1)
        |> reload.(socket.assigns.workbench)

      "delete" ->
        socket
        |> update_state(&delete_selected/1)
        |> reload.(socket.assigns.workbench)

      _other ->
        reload.(socket, socket.assigns.workbench)
    end
  end

  def drop_item(socket, drag_item_id, target_item_id, position, reload) do
    socket
    |> update_state(&drop_selected(&1, drag_item_id, target_item_id, position))
    |> reload.(socket.assigns.workbench)
  end

  def handle_keydown(socket, "Escape", reload) do
    cancel_entry(socket, reload)
  end

  def handle_keydown(socket, _key, reload) do
    reload.(socket, socket.assigns.workbench)
  end

  attr :menu_editor, :map, required: true

  def menu_editor(assigns)

  attr :items, :list, required: true
  attr :menu_editor, :map, required: true
  attr :depth, :integer, required: true

  def menu_tree_level(assigns) do
    ~H"""
    <%= for item <- @items do %>
      <li class="menu-editor-tree-item">
        <% editing? = draft_item?(@menu_editor, item.item_id) %>
        <% selected? = item.item_id == @menu_editor.selected_id %>
        <div
          class={[
            "menu-editor-row",
            if(selected?, do: "is-selected"),
            if(editing?, do: "is-editing")
          ]}
          data-testid="menu-editor-row"
          data-menu-item-id={item.item_id}
          data-menu-kind={item.kind}
          data-menu-label={row_label(item, @menu_editor.category_titles)}
          data-menu-can-drop-inside={to_string(item.kind == :submenu)}
          data-selected={to_string(selected?)}
          phx-click={unless(editing?, do: "menu_editor_select_item")}
          phx-value-item_id={unless(editing?, do: item.item_id)}
          style={"--menu-editor-depth: #{@depth};"}
        >
          <span class="menu-editor-row-handle" data-menu-drag-handle="true" title={translated("menuEditor.dragHandle")}>⋮⋮</span>
          <span class="menu-editor-row-kind" title={kind_label(item.kind)} aria-label={kind_label(item.kind)}>
            <.kind_icon kind={item.kind} />
          </span>

          <%= if editing? do %>
            <div class="menu-editor-row-title is-editing">
              <form
                class="menu-editor-entry-form"
                data-testid="menu-editor-entry-form"
                phx-change="change_menu_editor_entry"
                phx-submit="submit_menu_editor_entry"
              >
                <input
                  class="menu-editor-inline-input"
                  type="text"
                  name="menu_editor_entry[query]"
                  value={@menu_editor.draft_query}
                  placeholder={editing_placeholder(@menu_editor)}
                  autocomplete="off"
                />

                <div class="menu-editor-inline-search">
                  <div class="menu-editor-inline-search-head">
                    <div>
                      <strong><%= editing_title(@menu_editor) %></strong>
                      <span><%= editing_hint(@menu_editor) %></span>
                    </div>

                    <div class="menu-editor-inline-actions">
                      <%= if @menu_editor.draft.type == :page do %>
                        <button class="menu-editor-inline-action" data-testid="menu-editor-create-submenu" type="submit">
                          <%= translated("menuEditor.addSubmenu") %>
                        </button>
                      <% else %>
                        <button class="menu-editor-inline-action" type="submit">
                          <%= translated("menuEditor.addCategoryArchive") %>
                        </button>
                      <% end %>

                      <button class="menu-editor-inline-action" type="button" phx-click="cancel_menu_editor_entry">
                        <%= translated("Cancel") %>
                      </button>
                    </div>
                  </div>

                  <%= if @menu_editor.draft.type == :page do %>
                    <div class="menu-editor-picker-list">
                      <%= if @menu_editor.filtered_pages == [] do %>
                        <div class="menu-editor-picker-state"><%= translated("menuEditor.pagePicker.empty") %></div>
                      <% else %>
                        <%= for post <- @menu_editor.filtered_pages do %>
                          <button
                            class="menu-editor-picker-item"
                            type="button"
                            phx-click="select_menu_editor_page"
                            phx-value-post_id={post.id}
                          >
                            <span><%= post.title %></span>
                            <small><%= post.slug %></small>
                          </button>
                        <% end %>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="menu-editor-picker-list">
                      <%= if @menu_editor.filtered_categories == [] do %>
                        <div class="menu-editor-picker-state"><%= translated("menuEditor.categoryPicker.empty") %></div>
                      <% else %>
                        <%= for category <- @menu_editor.filtered_categories do %>
                          <button
                            class="menu-editor-picker-item"
                            type="button"
                            phx-click="select_menu_editor_category"
                            phx-value-name={category.name}
                          >
                            <span><%= category.title %></span>
                            <small><%= category.name %></small>
                          </button>
                        <% end %>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </form>
            </div>
          <% else %>
            <span class="menu-editor-row-title"><%= row_label(item, @menu_editor.category_titles) %></span>
          <% end %>
        </div>

        <%= if item.children != [] do %>
          <ul class="menu-editor-tree-level">
            <.menu_tree_level items={item.children} menu_editor={@menu_editor} depth={@depth + 1} />
          </ul>
        <% end %>
      </li>
    <% end %>
    """
  end

  attr :kind, :atom, required: true

  def kind_icon(assigns) do
    ~H"""
    <%= case @kind do %>
      <% :home -> %>
        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 2 2 7v7h4V9h4v5h4V7L8 2z" /></svg>
      <% :page -> %>
        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M3 2h7l3 3v9H3V2zm7 1.5V6h2.5L10 3.5z" /></svg>
      <% :category_archive -> %>
        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M2 3h12v3H2V3zm1 4h10v6H3V7zm2 1v1h6V8H5z" /></svg>
      <% _other -> %>
        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M2 3h12v2H2V3zm0 4h12v2H2V7zm0 4h12v2H2v-2z" /></svg>
    <% end %>
    """
  end

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  def row_label(item, category_titles) do
    if item.kind == :category_archive do
      Map.get(category_titles || %{}, item.slug, item.label)
    else
      item.label
    end
  end

  def kind_label(:home), do: translated("menuEditor.type.home")
  def kind_label(:page), do: translated("menuEditor.type.page")
  def kind_label(:category_archive), do: translated("menuEditor.type.categoryArchive")
  def kind_label(:submenu), do: translated("menuEditor.type.submenu")

  def draft_item?(menu_editor, item_id) do
    match?(%{item_id: ^item_id}, menu_editor.draft)
  end

  def editing_title(%{draft: %{type: :category}}), do: translated("menuEditor.addCategoryArchive")
  def editing_title(_menu_editor), do: translated("menuEditor.pagePicker.title")

  def editing_hint(%{draft: %{type: :category}}), do: translated("menuEditor.categoryPicker.hint")
  def editing_hint(_menu_editor), do: translated("menuEditor.createHint")

  def editing_placeholder(%{draft: %{type: :category}}), do: translated("menuEditor.newCategoryPlaceholder")
  def editing_placeholder(_menu_editor), do: translated("menuEditor.newEntryPlaceholder")

  defp ensure_state(assigns) do
    project_id = assigns.projects.active_project_id

    case assigns[:menu_editor_state] do
      %{project_id: ^project_id} = state -> state
      _other -> load_state(project_id)
    end
  end

  defp load_state(nil) do
    %{project_id: nil, items: [home_item()], selected_id: @home_item_id, draft: nil}
  end

  defp load_state(project_id) do
    {:ok, %{items: items}} = Menu.get_menu(project_id)
    items = Enum.map(items, &ui_item/1)

    %{
      project_id: project_id,
      items: items,
      selected_id: first_item_id(items),
      draft: nil
    }
  end

  defp build(_assigns, state) do
    categories = category_options(state.project_id)
    draft = state.draft
    draft_query = Map.get(draft || %{}, :query, "")

    %{
      title: translated("menuEditor.title"),
      description: translated("menuEditor.description"),
      items: state.items,
      selected_id: state.selected_id,
      draft: draft,
      draft_query: draft_query,
      filtered_pages:
        if(match?(%{type: :page}, draft),
          do: filter_page_posts(page_posts(state.project_id), draft_query),
          else: []
        ),
      filtered_categories:
        if(match?(%{type: :category}, draft),
          do: filter_categories(categories, draft_query),
          else: []
        ),
      category_titles: Map.new(categories, &{&1.name, &1.title}),
      can_move_up?: can_move_up?(state.items, state.selected_id),
      can_move_down?: can_move_down?(state.items, state.selected_id),
      can_indent?: can_indent?(state.items, state.selected_id),
      can_unindent?: can_unindent?(state.items, state.selected_id),
      can_delete?: can_delete?(state.selected_id),
      has_items?: state.items != []
    }
  end

  defp save(socket, reload, append_output) do
    state = socket.assigns.menu_editor_state

    {:ok, _menu} = Menu.update_menu(state.project_id, Enum.map(state.items, &persisted_item/1))

    socket
    |> append_output.(translated("menuEditor.tabTitle"), translated("menuEditor.saved"), nil, "info")
    |> reload.(socket.assigns.workbench)
  end

  defp confirm_category_draft(socket) do
    project_id = socket.assigns.projects.active_project_id
    draft = current_draft(socket.assigns)
    normalized = String.trim(Map.get(draft || %{}, :query, ""))

    category =
      Enum.find(category_options(project_id), fn option ->
        String.downcase(option.name) == String.downcase(normalized) or
          String.downcase(option.title) == String.downcase(normalized)
      end)

    category =
      cond do
        category != nil -> category
        normalized == "" -> %{name: "", title: ""}
        true ->
          {:ok, _metadata} = Metadata.add_category(project_id, normalized)
          %{name: normalized, title: normalized}
      end

    update_state(socket, &assign_category_to_draft(&1, category))
  end

  defp update_state(socket, updater) do
    state = ensure_state(socket.assigns)
    assign(socket, :menu_editor_state, updater.(state))
  end

  defp start_page_draft(state) do
    item = %{item_id: Ecto.UUID.generate(), kind: :page, label: translated("menuEditor.newPage"), slug: nil, children: [], is_home: false}
    {parent_path, index} = insert_target(state.items, state.selected_id)
    items = insert_item(state.items, parent_path, index, item)
    %{state | items: items, selected_id: item.item_id, draft: %{item_id: item.item_id, type: :page, query: ""}}
  end

  defp start_category_draft(state) do
    item = %{item_id: Ecto.UUID.generate(), kind: :category_archive, label: "", slug: nil, children: [], is_home: false}
    {parent_path, index} = insert_target(state.items, state.selected_id)
    items = insert_item(state.items, parent_path, index, item)
    %{state | items: items, selected_id: item.item_id, draft: %{item_id: item.item_id, type: :category, query: ""}}
  end

  defp finalize_submenu_draft(%{draft: %{item_id: item_id, query: query}} = state) do
    label = if(String.trim(query) == "", do: translated("menuEditor.newSubmenu"), else: String.trim(query))

    %{state | items: update_item(state.items, item_id, fn item -> %{item | kind: :submenu, label: label, slug: nil, children: item.children || []} end), draft: nil}
  end

  defp finalize_submenu_draft(state), do: state

  defp assign_page_to_draft(%{draft: %{item_id: item_id}} = state, post) do
    %{
      state
      | items:
          update_item(state.items, item_id, fn item ->
            %{item | kind: :page, label: post.title, slug: blank_to_nil(post.slug), children: []}
          end),
        draft: nil
    }
  end

  defp assign_page_to_draft(state, _post), do: state

  defp assign_category_to_draft(%{draft: %{item_id: item_id}} = state, category) do
    label = blank_to_nil(category.title) || category.name

    %{
      state
      | items:
          update_item(state.items, item_id, fn item ->
            %{item | kind: :category_archive, label: label, slug: category.name, children: []}
          end),
        draft: nil
    }
  end

  defp assign_category_to_draft(state, _category), do: state

  defp cancel_draft(%{draft: %{item_id: item_id}} = state) do
    items = remove_item(state.items, item_id)
    %{state | items: items, selected_id: first_item_id(items), draft: nil}
  end

  defp cancel_draft(state), do: state

  defp move_selected(%{selected_id: selected_id} = state, direction) when direction in [:up, :down] do
    case find_path(state.items, selected_id) do
      nil -> state
      [] -> state
      path ->
        parent_path = Enum.drop(path, -1)
        index = List.last(path)
        siblings = items_at_path(state.items, parent_path)
        delta = if(direction == :up, do: -1, else: 1)
        target_index = index + delta

        if target_index < 0 or target_index >= length(siblings) do
          state
        else
          reordered =
            List.pop_at(siblings, index)
            |> then(fn {item, rest} -> List.insert_at(rest, target_index, item) end)

          %{state | items: replace_items_at_path(state.items, parent_path, reordered)}
        end
    end
  end

  defp indent_selected(%{selected_id: selected_id} = state) do
    case find_path(state.items, selected_id) do
      nil -> state
      [] -> state
      path ->
        parent_path = Enum.drop(path, -1)
        index = List.last(path)

        cond do
          index <= 0 ->
            state

          true ->
            previous_sibling_path = parent_path ++ [index - 1]

            case item_at_path(state.items, previous_sibling_path) do
              %{kind: :submenu, item_id: sibling_id} ->
                case remove_item_with_value(state.items, selected_id) do
                  {_next_items, nil} -> state
                  {next_items, removed_item} ->
                    %{
                      state
                      | items: append_child(next_items, sibling_id, removed_item)
                    }
                end

              _other ->
                state
            end
        end
    end
  end

  defp unindent_selected(%{selected_id: selected_id} = state) do
    case find_path(state.items, selected_id) do
      nil -> state
      [] -> state
      [_root_index] -> state
      path ->
        parent_path = Enum.drop(path, -1)
        parent_index = List.last(parent_path)
        grand_parent_path = Enum.drop(parent_path, -1)

        case remove_item_with_value(state.items, selected_id) do
          {_next_items, nil} -> state
          {next_items, removed_item} ->
            %{
              state
              | items: insert_item(next_items, grand_parent_path, parent_index + 1, removed_item)
            }
        end
    end
  end

  defp delete_selected(%{selected_id: @home_item_id} = state), do: state

  defp delete_selected(%{selected_id: selected_id} = state) do
    items = remove_item(state.items, selected_id)
    %{state | items: items, selected_id: first_item_id(items), draft: nil}
  end

  defp drop_selected(state, drag_item_id, target_item_id, _position)
       when drag_item_id in [nil, ""] or target_item_id in [nil, ""] do
    state
  end

  defp drop_selected(state, drag_item_id, target_item_id, _position) when drag_item_id == target_item_id,
    do: state

  defp drop_selected(state, drag_item_id, target_item_id, position) do
    drag_path = find_path(state.items, drag_item_id)
    target_path = find_path(state.items, target_item_id)

    cond do
      is_nil(drag_path) or is_nil(target_path) ->
        state

      path_prefix?(drag_path, target_path) ->
        state

      true ->
        case remove_item_with_value(state.items, drag_item_id) do
          {_next_items, nil} ->
            state

          {next_items, dragged_item} ->
            case find_path(next_items, target_item_id) do
              nil ->
                state

              next_target_path ->
                insert_dropped_item(state, next_items, dragged_item, next_target_path, position)
            end
        end
    end
  end

  defp insert_dropped_item(state, next_items, dragged_item, target_path, "inside") do
    case item_at_path(next_items, target_path) do
      %{kind: :submenu} ->
        %{state | items: insert_item(next_items, target_path, 0, dragged_item), selected_id: dragged_item.item_id}

      _other ->
        state
    end
  end

  defp insert_dropped_item(state, next_items, dragged_item, target_path, "before") do
    parent_path = Enum.drop(target_path, -1)
    index = List.last(target_path)
    %{state | items: insert_item(next_items, parent_path, index, dragged_item), selected_id: dragged_item.item_id}
  end

  defp insert_dropped_item(state, next_items, dragged_item, target_path, _position) do
    parent_path = Enum.drop(target_path, -1)
    index = List.last(target_path) + 1
    %{state | items: insert_item(next_items, parent_path, index, dragged_item), selected_id: dragged_item.item_id}
  end

  defp current_draft(assigns), do: Map.get(assigns.menu_editor_state || %{}, :draft)

  defp page_posts(nil), do: []

  defp page_posts(project_id) do
    Repo.all(from post in Post, where: post.project_id == ^project_id, order_by: [asc: post.title, asc: post.slug])
    |> Enum.filter(&("page" in (&1.categories || [])))
  end

  defp page_post(nil, _post_id), do: nil

  defp page_post(project_id, post_id) do
    Enum.find(page_posts(project_id), &(&1.id == post_id))
  end

  defp filter_page_posts(posts, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(posts, fn post ->
      normalized == "" or
        String.contains?(String.downcase(post.title || ""), normalized) or
        String.contains?(String.downcase(post.slug || ""), normalized)
    end)
  end

  defp category_options(nil), do: []

  defp category_options(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    Enum.map(metadata.categories || [], fn name ->
      title = get_in(metadata.category_settings || %{}, [name, "title"])
      %{name: name, title: blank_to_nil(title) || name}
    end)
  end

  defp filter_categories(categories, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(categories, fn category ->
      normalized == "" or
        String.contains?(String.downcase(category.name), normalized) or
        String.contains?(String.downcase(category.title), normalized)
    end)
  end

  defp can_move_up?(items, selected_id) do
    case find_path(items, selected_id) do
      [_parent, index] -> index > 0
      [index] -> index > 0
      path when is_list(path) -> List.last(path) > 0
      _other -> false
    end
  end

  defp can_move_down?(items, selected_id) do
    case find_path(items, selected_id) do
      nil -> false
      path ->
        parent_path = Enum.drop(path, -1)
        index = List.last(path)
        index < length(items_at_path(items, parent_path)) - 1
    end
  end

  defp can_indent?(items, selected_id) do
    case find_path(items, selected_id) do
      nil -> false
      [] -> false
      [_index] = path ->
        index = List.last(path)
        index > 0 and match?(%{kind: :submenu}, item_at_path(items, [index - 1]))

      path ->
        index = List.last(path)

        index > 0 and
          match?(%{kind: :submenu}, item_at_path(items, Enum.drop(path, -1) ++ [index - 1]))
    end
  end

  defp can_unindent?(items, selected_id) do
    case find_path(items, selected_id) do
      [_index] -> false
      path when is_list(path) -> length(path) > 1
      _other -> false
    end
  end

  defp can_delete?(selected_id), do: is_binary(selected_id) and selected_id != @home_item_id

  defp home_item do
    %{item_id: @home_item_id, kind: :home, label: "Home", slug: nil, children: [], is_home: true}
  end

  defp ui_item(%{kind: :home}), do: home_item()

  defp ui_item(item) do
    kind = Map.get(item, :kind, :page)

    %{
      item_id: Ecto.UUID.generate(),
      kind: kind,
      label: Map.get(item, :label, ""),
      slug: Map.get(item, :slug),
      children: Enum.map(Map.get(item, :children, []), &ui_item/1),
      is_home: false
    }
  end

  defp persisted_item(%{kind: :home}), do: %{kind: :home, label: "Home", slug: nil}

  defp persisted_item(%{kind: :submenu} = item) do
    %{kind: :submenu, label: item.label, slug: nil, children: Enum.map(item.children || [], &persisted_item/1)}
  end

  defp persisted_item(item) do
    %{kind: item.kind, label: item.label, slug: item.slug}
  end

  defp insert_target(items, nil), do: {[], length(items)}

  defp insert_target(items, selected_id) do
    case find_path(items, selected_id) do
      nil -> {[], length(items)}
      [] -> {[], length(items)}
      path ->
        case item_at_path(items, path) do
          %{kind: :submenu} -> {path, 0}
          _other -> {Enum.drop(path, -1), List.last(path) + 1}
        end
    end
  end

  defp first_item_id([item | _rest]), do: item.item_id
  defp first_item_id([]), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) do
    trimmed = String.trim(to_string(value))
    if trimmed == "", do: nil, else: trimmed
  end

  defp path_prefix?(prefix, path) when length(prefix) > length(path), do: false
  defp path_prefix?(prefix, path), do: Enum.take(path, length(prefix)) == prefix

  defp find_path(items, item_id, path \\ []) do
    Enum.find_value(Enum.with_index(items), fn {item, index} ->
      next_path = path ++ [index]

      cond do
        item.item_id == item_id ->
          next_path

        item.children != [] ->
          find_path(item.children, item_id, next_path)

        true ->
          nil
      end
    end)
  end

  defp item_at_path(_items, []), do: nil

  defp item_at_path(items, [index]) do
    Enum.at(items, index)
  end

  defp item_at_path(items, [index | rest]) do
    case Enum.at(items, index) do
      nil -> nil
      item -> item_at_path(item.children || [], rest)
    end
  end

  defp items_at_path(items, []), do: items

  defp items_at_path(items, [index | rest]) do
    case Enum.at(items, index) do
      nil -> []
      item -> items_at_path(item.children || [], rest)
    end
  end

  defp replace_items_at_path(_items, [], replacement), do: replacement

  defp replace_items_at_path(items, [index | rest], replacement) do
    List.update_at(items, index, fn item ->
      %{item | children: replace_items_at_path(item.children || [], rest, replacement)}
    end)
  end

  defp update_item(items, item_id, updater) do
    Enum.map(items, fn item ->
      cond do
        item.item_id == item_id -> updater.(item)
        item.children != [] -> %{item | children: update_item(item.children, item_id, updater)}
        true -> item
      end
    end)
  end

  defp insert_item(items, [], index, item) do
    List.insert_at(items, index, item)
  end

  defp insert_item(items, [head | tail], index, item) do
    List.update_at(items, head, fn current ->
      %{current | children: insert_item(current.children || [], tail, index, item)}
    end)
  end

  defp remove_item(items, item_id) do
    remove_item_with_value(items, item_id) |> elem(0)
  end

  defp remove_item_with_value(items, item_id) do
    Enum.reduce_while(Enum.with_index(items), {items, nil}, fn {item, index}, _acc ->
      cond do
        item.item_id == item_id ->
          {:halt, {List.delete_at(items, index), item}}

        item.children != [] ->
          {next_children, removed_item} = remove_item_with_value(item.children, item_id)

          if removed_item do
            {:halt, {List.replace_at(items, index, %{item | children: next_children}), removed_item}}
          else
            {:cont, {items, nil}}
          end

        true ->
          {:cont, {items, nil}}
      end
    end)
  end

  defp append_child(items, parent_item_id, child) do
    update_item(items, parent_item_id, fn item ->
      %{item | children: (item.children || []) ++ [child]}
    end)
  end
end
