defmodule BDS.Desktop.ShellLive.MenuEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData

  alias BDS.Desktop.ShellLive.MenuEditor.{
    DraftManagement,
    PageCategory,
    State,
    TreeOps,
    TreePredicates
  }

  embed_templates("menu_editor_html/*")

  @spec assign_socket(term()) :: term()
  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :menu_editor, id: tab_id} ->
        state = State.ensure_state(socket.assigns)
        menu_editor = State.build(socket.assigns, state)

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

  @spec select_item(term(), term(), term()) :: term()
  def select_item(socket, item_id, reload) do
    socket
    |> State.update_state(fn state -> %{state | selected_id: item_id} end)
    |> reload.(socket.assigns.workbench)
  end

  @spec change_entry(term(), term(), term()) :: term()
  def change_entry(socket, params, reload) do
    query = Map.get(params, "query", "")

    socket
    |> State.update_state(fn state -> put_in(state, [:draft, :query], query) end)
    |> reload.(socket.assigns.workbench)
  end

  @spec submit_entry(term(), term()) :: term()
  def submit_entry(socket, reload) do
    case DraftManagement.current_draft(socket.assigns) do
      %{type: :page} ->
        socket
        |> State.update_state(&DraftManagement.finalize_submenu_draft/1)
        |> reload.(socket.assigns.workbench)

      %{type: :category} ->
        socket
        |> DraftManagement.confirm_category_draft(&State.update_state/2)
        |> reload.(socket.assigns.workbench)

      _other ->
        reload.(socket, socket.assigns.workbench)
    end
  end

  @spec cancel_entry(term(), term()) :: term()
  def cancel_entry(socket, reload) do
    socket
    |> State.update_state(&DraftManagement.cancel_draft/1)
    |> reload.(socket.assigns.workbench)
  end

  @spec select_page(term(), term(), term()) :: term()
  def select_page(socket, post_id, reload) do
    case PageCategory.page_post(socket.assigns.projects.active_project_id, post_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      post ->
        socket
        |> State.update_state(&DraftManagement.assign_page_to_draft(&1, post))
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec select_category(term(), term(), term()) :: term()
  def select_category(socket, name, reload) do
    project_id = socket.assigns.projects.active_project_id

    case Enum.find(PageCategory.category_options(project_id), &(&1.name == name)) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      category ->
        socket
        |> State.update_state(&DraftManagement.assign_category_to_draft(&1, category))
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec toolbar_action(term(), term(), term(), term()) :: term()
  def toolbar_action(socket, action, reload, append_output) do
    case action do
      "add-entry" ->
        socket
        |> State.update_state(&DraftManagement.start_page_draft/1)
        |> reload.(socket.assigns.workbench)

      "add-category-archive" ->
        socket
        |> State.update_state(&DraftManagement.start_category_draft/1)
        |> reload.(socket.assigns.workbench)

      "save" ->
        State.save(socket, reload, append_output)

      "move-up" ->
        socket
        |> State.update_state(&TreeOps.move_selected(&1, :up))
        |> reload.(socket.assigns.workbench)

      "move-down" ->
        socket
        |> State.update_state(&TreeOps.move_selected(&1, :down))
        |> reload.(socket.assigns.workbench)

      "indent" ->
        socket
        |> State.update_state(&TreeOps.indent_selected/1)
        |> reload.(socket.assigns.workbench)

      "unindent" ->
        socket
        |> State.update_state(&TreeOps.unindent_selected/1)
        |> reload.(socket.assigns.workbench)

      "delete" ->
        socket
        |> State.update_state(&TreeOps.delete_selected/1)
        |> reload.(socket.assigns.workbench)

      _other ->
        reload.(socket, socket.assigns.workbench)
    end
  end

  @spec drop_item(term(), term(), term(), term(), term()) :: term()
  def drop_item(socket, drag_item_id, target_item_id, position, reload) do
    socket
    |> State.update_state(&TreeOps.drop_selected(&1, drag_item_id, target_item_id, position))
    |> reload.(socket.assigns.workbench)
  end

  @spec handle_keydown(term(), term(), term()) :: term()
  def handle_keydown(socket, "Escape", reload) do
    cancel_entry(socket, reload)
  end

  def handle_keydown(socket, _key, reload) do
    reload.(socket, socket.assigns.workbench)
  end

  attr(:menu_editor, :map, required: true)

  @spec menu_editor(term()) :: term()
  def menu_editor(assigns)

  attr(:items, :list, required: true)
  attr(:menu_editor, :map, required: true)
  attr(:depth, :integer, required: true)

  @spec menu_tree_level(term()) :: term()
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

  attr(:kind, :atom, required: true)

  @spec kind_icon(term()) :: term()
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

  @spec translated(term(), term()) :: term()
  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  @spec row_label(term(), term()) :: term()
  def row_label(item, category_titles) do
    if item.kind == :category_archive do
      Map.get(category_titles || %{}, item.slug, item.label)
    else
      item.label
    end
  end

  @spec kind_label(term()) :: term()
  def kind_label(:home), do: translated("menuEditor.type.home")
  def kind_label(:page), do: translated("menuEditor.type.page")
  def kind_label(:category_archive), do: translated("menuEditor.type.categoryArchive")
  def kind_label(:submenu), do: translated("menuEditor.type.submenu")

  defdelegate draft_item?(menu_editor, item_id), to: TreePredicates

  @spec editing_title(term()) :: term()
  def editing_title(%{draft: %{type: :category}}), do: translated("menuEditor.addCategoryArchive")
  def editing_title(_menu_editor), do: translated("menuEditor.pagePicker.title")

  @spec editing_hint(term()) :: term()
  def editing_hint(%{draft: %{type: :category}}), do: translated("menuEditor.categoryPicker.hint")
  def editing_hint(_menu_editor), do: translated("menuEditor.createHint")

  @spec editing_placeholder(term()) :: term()
  def editing_placeholder(%{draft: %{type: :category}}),
    do: translated("menuEditor.newCategoryPlaceholder")

  def editing_placeholder(_menu_editor), do: translated("menuEditor.newEntryPlaceholder")
end
