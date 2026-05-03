defmodule BDS.Desktop.ShellLive.MenuEditor.DraftManagement do
  @moduledoc false

  alias BDS.Metadata
  alias BDS.Desktop.ShellLive.MenuEditor.PageCategory
  alias BDS.Desktop.ShellLive.MenuEditor.TreeOps
  use Gettext, backend: BDS.Gettext

  @spec current_draft(term()) :: term()
  def current_draft(assigns), do: Map.get(assigns.menu_editor_state || %{}, :draft)

  @spec start_page_draft(term()) :: term()
  def start_page_draft(state) do
    item = %{
      item_id: Ecto.UUID.generate(),
      kind: :page,
      label: dgettext("ui", "New Page"),
      slug: nil,
      children: [],
      is_home: false
    }

    {parent_path, index} = TreeOps.insert_target(state.items, state.selected_id)
    items = TreeOps.insert_item(state.items, parent_path, index, item)

    %{
      state
      | items: items,
        selected_id: item.item_id,
        draft: %{item_id: item.item_id, type: :page, query: ""}
    }
  end

  @spec start_category_draft(term()) :: term()
  def start_category_draft(state) do
    item = %{
      item_id: Ecto.UUID.generate(),
      kind: :category_archive,
      label: "",
      slug: nil,
      children: [],
      is_home: false
    }

    {parent_path, index} = TreeOps.insert_target(state.items, state.selected_id)
    items = TreeOps.insert_item(state.items, parent_path, index, item)

    %{
      state
      | items: items,
        selected_id: item.item_id,
        draft: %{item_id: item.item_id, type: :category, query: ""}
    }
  end

  @spec finalize_submenu_draft(term()) :: term()
  def finalize_submenu_draft(%{draft: %{item_id: item_id, query: query}} = state) do
    label =
      if(String.trim(query) == "",
        do: dgettext("ui", "New Submenu"),
        else: String.trim(query)
      )

    %{
      state
      | items:
          TreeOps.update_item(state.items, item_id, fn item ->
            %{item | kind: :submenu, label: label, slug: nil, children: item.children || []}
          end),
        draft: nil
    }
  end

  def finalize_submenu_draft(state), do: state

  @spec assign_page_to_draft(term(), term()) :: term()
  def assign_page_to_draft(%{draft: %{item_id: item_id}} = state, post) do
    %{
      state
      | items:
          TreeOps.update_item(state.items, item_id, fn item ->
            %{
              item
              | kind: :page,
                label: post.title,
                slug: PageCategory.blank_to_nil(post.slug),
                children: []
            }
          end),
        draft: nil
    }
  end

  def assign_page_to_draft(state, _post), do: state

  @spec assign_category_to_draft(term(), term()) :: term()
  def assign_category_to_draft(%{draft: %{item_id: item_id}} = state, category) do
    label = PageCategory.blank_to_nil(category.title) || category.name

    %{
      state
      | items:
          TreeOps.update_item(state.items, item_id, fn item ->
            %{item | kind: :category_archive, label: label, slug: category.name, children: []}
          end),
        draft: nil
    }
  end

  def assign_category_to_draft(state, _category), do: state

  @spec cancel_draft(term()) :: term()
  def cancel_draft(%{draft: %{item_id: item_id}} = state) do
    items = TreeOps.remove_item(state.items, item_id)
    %{state | items: items, selected_id: TreeOps.first_item_id(items), draft: nil}
  end

  def cancel_draft(state), do: state

  @spec confirm_category_draft(term(), term()) :: term()
  def confirm_category_draft(socket, update_state_fun) do
    project_id = socket.assigns.projects.active_project_id
    draft = current_draft(socket.assigns)
    normalized = String.trim(Map.get(draft || %{}, :query, ""))

    category =
      Enum.find(PageCategory.category_options(project_id), fn option ->
        String.downcase(option.name) == String.downcase(normalized) or
          String.downcase(option.title) == String.downcase(normalized)
      end)

    category =
      cond do
        category != nil ->
          category

        normalized == "" ->
          %{name: "", title: ""}

        true ->
          {:ok, _metadata} = Metadata.add_category(project_id, normalized)
          %{name: normalized, title: normalized}
      end

    update_state_fun.(socket, &assign_category_to_draft(&1, category))
  end
end
