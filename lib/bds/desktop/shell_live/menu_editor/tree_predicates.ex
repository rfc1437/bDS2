defmodule BDS.Desktop.ShellLive.MenuEditor.TreePredicates do
  @moduledoc false

  alias BDS.Desktop.ShellLive.MenuEditor.TreeOps

  @spec can_move_up?(term(), term()) :: term()
  def can_move_up?(items, selected_id) do
    case TreeOps.find_path(items, selected_id) do
      [_parent, index] -> index > 0
      [index] -> index > 0
      path when is_list(path) -> List.last(path) > 0
      _other -> false
    end
  end

  @spec can_move_down?(term(), term()) :: term()
  def can_move_down?(items, selected_id) do
    case TreeOps.find_path(items, selected_id) do
      nil ->
        false

      path ->
        parent_path = Enum.drop(path, -1)
        index = List.last(path)
        index < length(TreeOps.items_at_path(items, parent_path)) - 1
    end
  end

  @spec can_indent?(term(), term()) :: term()
  def can_indent?(items, selected_id) do
    case TreeOps.find_path(items, selected_id) do
      nil ->
        false

      [] ->
        false

      [_index] = path ->
        index = List.last(path)
        index > 0 and match?(%{kind: :submenu}, TreeOps.item_at_path(items, [index - 1]))

      path ->
        index = List.last(path)

        index > 0 and
          match?(
            %{kind: :submenu},
            TreeOps.item_at_path(items, Enum.drop(path, -1) ++ [index - 1])
          )
    end
  end

  @spec can_unindent?(term(), term()) :: term()
  def can_unindent?(items, selected_id) do
    case TreeOps.find_path(items, selected_id) do
      [_index] -> false
      path when is_list(path) -> length(path) > 1
      _other -> false
    end
  end

  @spec can_delete?(term()) :: term()
  def can_delete?(selected_id),
    do: is_binary(selected_id) and selected_id != TreeOps.home_item_id()

  @spec draft_item?(term(), term()) :: term()
  def draft_item?(menu_editor, item_id) do
    match?(%{item_id: ^item_id}, menu_editor.draft)
  end
end
