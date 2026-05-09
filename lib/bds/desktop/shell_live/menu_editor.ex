defmodule BDS.Desktop.ShellLive.MenuEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  use Gettext, backend: BDS.Gettext

  alias BDS.Desktop.ShellLive.Notify

  alias BDS.Desktop.ShellLive.MenuEditor.{
    DraftManagement,
    PageCategory,
    State,
    TreeOps,
    TreePredicates
  }

  embed_templates("menu_editor_html/*")

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:action]))
    socket = do_save(socket)
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> ensure_project_assigns()
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    menu_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("menu_editor_select_item", %{"item_id" => item_id}, socket) do
    socket =
      socket
      |> State.update_state(fn state -> %{state | selected_id: item_id} end)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("change_menu_editor_entry", %{"menu_editor_entry" => params}, socket) do
    query = Map.get(params, "query", "")

    socket =
      socket
      |> State.update_state(fn state -> put_in(state, [:draft, :query], query) end)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("submit_menu_editor_entry", _params, socket) do
    socket =
      case DraftManagement.current_draft(socket.assigns) do
        %{type: :page} ->
          socket
          |> State.update_state(&DraftManagement.finalize_submenu_draft/1)
          |> build_data()

        %{type: :category} ->
          socket
          |> DraftManagement.confirm_category_draft(&State.update_state/2)
          |> build_data()

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_menu_editor_entry", _params, socket) do
    socket =
      socket
      |> State.update_state(&DraftManagement.cancel_draft/1)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("select_menu_editor_page", %{"post_id" => post_id}, socket) do
    socket =
      case PageCategory.page_post(socket.assigns.projects.active_project_id, post_id) do
        nil ->
          socket

        post ->
          socket
          |> State.update_state(&DraftManagement.assign_page_to_draft(&1, post))
          |> build_data()
      end

    {:noreply, socket}
  end

  def handle_event("select_menu_editor_category", %{"name" => name}, socket) do
    project_id = socket.assigns.projects.active_project_id

    socket =
      case Enum.find(PageCategory.category_options(project_id), &(&1.name == name)) do
        nil ->
          socket

        category ->
          socket
          |> State.update_state(&DraftManagement.assign_category_to_draft(&1, category))
          |> build_data()
      end

    {:noreply, socket}
  end

  def handle_event("menu_editor_toolbar_action", %{"action" => action}, socket) do
    socket = handle_toolbar_action(socket, action)
    {:noreply, socket}
  end

  def handle_event(
        "menu_editor_drop_item",
        %{
          "drag_item_id" => drag_item_id,
          "target_item_id" => target_item_id,
          "position" => position
        },
        socket
      ) do
    socket =
      socket
      |> State.update_state(&TreeOps.drop_selected(&1, drag_item_id, target_item_id, position))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("menu_editor_keydown", %{"key" => "Escape"}, socket) do
    socket =
      socket
      |> State.update_state(&DraftManagement.cancel_draft/1)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("menu_editor_keydown", _params, socket) do
    {:noreply, socket}
  end

  defp handle_toolbar_action(socket, "add-entry") do
    socket
    |> State.update_state(&DraftManagement.start_page_draft/1)
    |> build_data()
  end

  defp handle_toolbar_action(socket, "add-category-archive") do
    socket
    |> State.update_state(&DraftManagement.start_category_draft/1)
    |> build_data()
  end

  defp handle_toolbar_action(socket, "save") do
    do_save(socket)
  end

  defp handle_toolbar_action(socket, "move-up") do
    socket
    |> State.update_state(&TreeOps.move_selected(&1, :up))
    |> build_data()
  end

  defp handle_toolbar_action(socket, "move-down") do
    socket
    |> State.update_state(&TreeOps.move_selected(&1, :down))
    |> build_data()
  end

  defp handle_toolbar_action(socket, "indent") do
    socket
    |> State.update_state(&TreeOps.indent_selected/1)
    |> build_data()
  end

  defp handle_toolbar_action(socket, "unindent") do
    socket
    |> State.update_state(&TreeOps.unindent_selected/1)
    |> build_data()
  end

  defp handle_toolbar_action(socket, "delete") do
    socket
    |> State.update_state(&TreeOps.delete_selected/1)
    |> build_data()
  end

  defp handle_toolbar_action(socket, _other), do: socket

  defp do_save(socket) do
    state = socket.assigns.menu_editor_state

    {:ok, _menu} =
      BDS.Menu.update_menu(
        state.project_id,
        Enum.map(state.items, &TreeOps.persisted_item/1)
      )

    notify_output(dgettext("ui", "Blog Menu"), dgettext("ui", "Blog menu saved"), "info")
    socket |> build_data()
  end

  defp ensure_project_assigns(socket) do
    project_id = socket.assigns.project_id

    if Map.has_key?(socket.assigns, :projects) do
      socket
    else
      assign(socket, :projects, %{active_project_id: project_id})
    end
  end

  defp build_data(socket) do
    tab_id = socket.assigns.current_tab.id
    state = State.ensure_state(socket.assigns)
    menu_editor = State.build(socket.assigns, state)

    tab_meta =
      Map.put(socket.assigns.tab_meta, {:menu_editor, tab_id}, %{
        title: dgettext("ui", "Blog Menu"),
        subtitle:
          dgettext(
            "ui",
            "Manage the central blog navigation outline and save it to meta/menu.opml."
          )
      })

    socket
    |> assign(:menu_editor_state, state)
    |> assign(:menu_editor, menu_editor)
    |> assign(:tab_meta, tab_meta)
  end

  defp notify_output(title, message, level) do
    Notify.output(title, message, level)
  end

  attr(:menu_editor, :map, required: true)

  @spec menu_editor(term()) :: term()
  def menu_editor(assigns)

  attr(:items, :list, required: true)
  attr(:menu_editor, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:myself, :any, required: true)

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
          phx-target={@myself}
          style={"--menu-editor-depth: #{@depth};"}
        >
          <span class="menu-editor-row-handle" data-menu-drag-handle="true" title={dgettext("ui", "Drag menu item")}>⋮⋮</span>
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
                phx-target={@myself}
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
                          <%= dgettext("ui", "Add Submenu") %>
                        </button>
                      <% else %>
                        <button class="menu-editor-inline-action" type="submit">
                          <%= dgettext("ui", "Add Category Archive") %>
                        </button>
                      <% end %>

                      <button class="menu-editor-inline-action" type="button" phx-click="cancel_menu_editor_entry" phx-target={@myself}>
                        <%= dgettext("ui", "Cancel") %>
                      </button>
                    </div>
                  </div>

                  <%= if @menu_editor.draft.type == :page do %>
                    <div class="menu-editor-picker-list">
                      <%= if @menu_editor.filtered_pages == [] do %>
                        <div class="menu-editor-picker-state"><%= dgettext("ui", "No matching pages found.") %></div>
                      <% else %>
                        <%= for post <- @menu_editor.filtered_pages do %>
                          <button
                            class="menu-editor-picker-item"
                            type="button"
                            phx-click="select_menu_editor_page"
                            phx-value-post_id={post.id}
                            phx-target={@myself}
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
                        <div class="menu-editor-picker-state"><%= dgettext("ui", "No matching categories found.") %></div>
                      <% else %>
                        <%= for category <- @menu_editor.filtered_categories do %>
                          <button
                            class="menu-editor-picker-item"
                            type="button"
                            phx-click="select_menu_editor_category"
                            phx-value-name={category.name}
                            phx-target={@myself}
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
            <.menu_tree_level items={item.children} menu_editor={@menu_editor} depth={@depth + 1} myself={@myself} />
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

  @spec row_label(term(), term()) :: term()
  def row_label(item, category_titles) do
    if item.kind == :category_archive do
      Map.get(category_titles || %{}, item.slug, item.label)
    else
      item.label
    end
  end

  @spec kind_label(term()) :: term()
  def kind_label(:home), do: dgettext("ui", "Home")
  def kind_label(:page), do: dgettext("ui", "Page")
  def kind_label(:category_archive), do: dgettext("ui", "Category Archive")
  def kind_label(:submenu), do: dgettext("ui", "Submenu")

  defdelegate draft_item?(menu_editor, item_id), to: TreePredicates

  @spec editing_title(term()) :: term()
  def editing_title(%{draft: %{type: :category}}), do: dgettext("ui", "Add Category Archive")
  def editing_title(_menu_editor), do: dgettext("ui", "Select Page")

  @spec editing_hint(term()) :: term()
  def editing_hint(%{draft: %{type: :category}}),
    do: dgettext("ui", "Select an existing category or press Enter to create a new archive entry")

  def editing_hint(_menu_editor),
    do: dgettext("ui", "Select a page below or press Enter to create a submenu")

  @spec editing_placeholder(term()) :: term()
  def editing_placeholder(%{draft: %{type: :category}}),
    do: dgettext("ui", "Type a category name")

  def editing_placeholder(_menu_editor), do: dgettext("ui", "Type a page title or submenu label")
end
