defmodule BDS.Desktop.ShellLive.MenuEditor.State do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData
  alias BDS.Menu
  alias BDS.Desktop.ShellLive.MenuEditor.{PageCategory, TreeOps, TreePredicates}

  def ensure_state(assigns) do
    project_id = assigns.projects.active_project_id

    case assigns[:menu_editor_state] do
      %{project_id: ^project_id} = state -> state
      _other -> load_state(project_id)
    end
  end

  def update_state(socket, updater) do
    state = ensure_state(socket.assigns)
    assign(socket, :menu_editor_state, updater.(state))
  end

  def build(_assigns, state) do
    categories = PageCategory.category_options(state.project_id)
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
          do: PageCategory.filter_page_posts(PageCategory.page_posts(state.project_id), draft_query),
          else: []
        ),
      filtered_categories:
        if(match?(%{type: :category}, draft),
          do: PageCategory.filter_categories(categories, draft_query),
          else: []
        ),
      category_titles: Map.new(categories, &{&1.name, &1.title}),
      can_move_up?: TreePredicates.can_move_up?(state.items, state.selected_id),
      can_move_down?: TreePredicates.can_move_down?(state.items, state.selected_id),
      can_indent?: TreePredicates.can_indent?(state.items, state.selected_id),
      can_unindent?: TreePredicates.can_unindent?(state.items, state.selected_id),
      can_delete?: TreePredicates.can_delete?(state.selected_id),
      has_items?: state.items != []
    }
  end

  def save(socket, reload, append_output) do
    state = socket.assigns.menu_editor_state

    {:ok, _menu} =
      Menu.update_menu(state.project_id, Enum.map(state.items, &TreeOps.persisted_item/1))

    socket
    |> append_output.(translated("menuEditor.tabTitle"), translated("menuEditor.saved"), nil, "info")
    |> reload.(socket.assigns.workbench)
  end

  defp load_state(nil) do
    %{project_id: nil, items: [TreeOps.home_item()], selected_id: TreeOps.home_item_id(), draft: nil}
  end

  defp load_state(project_id) do
    {:ok, %{items: items}} = Menu.get_menu(project_id)
    items = Enum.map(items, &TreeOps.ui_item/1)

    %{
      project_id: project_id,
      items: items,
      selected_id: TreeOps.first_item_id(items),
      draft: nil
    }
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
