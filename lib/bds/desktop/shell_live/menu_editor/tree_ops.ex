defmodule BDS.Desktop.ShellLive.MenuEditor.TreeOps do
  @moduledoc false

  @home_item_id "menu-home"

  @spec home_item_id() :: term()
  def home_item_id, do: @home_item_id

  @spec home_item() :: term()
  def home_item do
    %{item_id: @home_item_id, kind: :home, label: "Home", slug: nil, children: [], is_home: true}
  end

  @spec ui_item(term()) :: term()
  def ui_item(%{kind: :home}), do: home_item()

  def ui_item(item) do
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

  @spec persisted_item(term()) :: term()
  def persisted_item(%{kind: :home}), do: %{kind: :home, label: "Home", slug: nil}

  def persisted_item(%{kind: :submenu} = item) do
    %{
      kind: :submenu,
      label: item.label,
      slug: nil,
      children: Enum.map(item.children || [], &persisted_item/1)
    }
  end

  def persisted_item(item) do
    %{kind: item.kind, label: item.label, slug: item.slug}
  end

  @spec first_item_id(term()) :: term()
  def first_item_id([item | _rest]), do: item.item_id
  def first_item_id([]), do: nil

  @spec insert_target(term(), term()) :: term()
  def insert_target(items, nil), do: {[], length(items)}

  def insert_target(items, selected_id) do
    case find_path(items, selected_id) do
      nil ->
        {[], length(items)}

      [] ->
        {[], length(items)}

      path ->
        case item_at_path(items, path) do
          %{kind: :submenu} -> {path, 0}
          _other -> {Enum.drop(path, -1), List.last(path) + 1}
        end
    end
  end

  @spec path_prefix?(term(), term()) :: term()
  def path_prefix?(prefix, path) when length(prefix) > length(path), do: false
  @spec path_prefix?(term(), term()) :: term()
  def path_prefix?(prefix, path), do: Enum.take(path, length(prefix)) == prefix

  @spec find_path(term(), term(), term()) :: term()
  def find_path(items, item_id, path \\ []) do
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

  @spec item_at_path(term(), term()) :: term()
  def item_at_path(_items, []), do: nil

  def item_at_path(items, [index]) do
    Enum.at(items, index)
  end

  def item_at_path(items, [index | rest]) do
    case Enum.at(items, index) do
      nil -> nil
      item -> item_at_path(item.children || [], rest)
    end
  end

  @spec items_at_path(term(), term()) :: term()
  def items_at_path(items, []), do: items

  def items_at_path(items, [index | rest]) do
    case Enum.at(items, index) do
      nil -> []
      item -> items_at_path(item.children || [], rest)
    end
  end

  @spec replace_items_at_path(term(), term(), term()) :: term()
  def replace_items_at_path(_items, [], replacement), do: replacement

  def replace_items_at_path(items, [index | rest], replacement) do
    List.update_at(items, index, fn item ->
      %{item | children: replace_items_at_path(item.children || [], rest, replacement)}
    end)
  end

  @spec update_item(term(), term(), term()) :: term()
  def update_item(items, item_id, updater) do
    Enum.map(items, fn item ->
      cond do
        item.item_id == item_id -> updater.(item)
        item.children != [] -> %{item | children: update_item(item.children, item_id, updater)}
        true -> item
      end
    end)
  end

  @spec insert_item(term(), term(), term(), term()) :: term()
  def insert_item(items, [], index, item) do
    List.insert_at(items, index, item)
  end

  def insert_item(items, [head | tail], index, item) do
    List.update_at(items, head, fn current ->
      %{current | children: insert_item(current.children || [], tail, index, item)}
    end)
  end

  @spec remove_item(term(), term()) :: term()
  def remove_item(items, item_id) do
    remove_item_with_value(items, item_id) |> elem(0)
  end

  @spec remove_item_with_value(term(), term()) :: term()
  def remove_item_with_value(items, item_id) do
    Enum.reduce_while(Enum.with_index(items), {items, nil}, fn {item, index}, _acc ->
      cond do
        item.item_id == item_id ->
          {:halt, {List.delete_at(items, index), item}}

        item.children != [] ->
          {next_children, removed_item} = remove_item_with_value(item.children, item_id)

          if removed_item do
            {:halt,
             {List.replace_at(items, index, %{item | children: next_children}), removed_item}}
          else
            {:cont, {items, nil}}
          end

        true ->
          {:cont, {items, nil}}
      end
    end)
  end

  @spec append_child(term(), term(), term()) :: term()
  def append_child(items, parent_item_id, child) do
    update_item(items, parent_item_id, fn item ->
      %{item | children: (item.children || []) ++ [child]}
    end)
  end

  @spec move_selected(term(), term()) :: term()
  def move_selected(%{selected_id: selected_id} = state, direction)
      when direction in [:up, :down] do
    case find_path(state.items, selected_id) do
      nil ->
        state

      [] ->
        state

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

  @spec indent_selected(term()) :: term()
  def indent_selected(%{selected_id: selected_id} = state) do
    case find_path(state.items, selected_id) do
      nil ->
        state

      [] ->
        state

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
                  {_next_items, nil} ->
                    state

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

  @spec unindent_selected(term()) :: term()
  def unindent_selected(%{selected_id: selected_id} = state) do
    case find_path(state.items, selected_id) do
      nil ->
        state

      [] ->
        state

      [_root_index] ->
        state

      path ->
        parent_path = Enum.drop(path, -1)
        parent_index = List.last(parent_path)
        grand_parent_path = Enum.drop(parent_path, -1)

        case remove_item_with_value(state.items, selected_id) do
          {_next_items, nil} ->
            state

          {next_items, removed_item} ->
            %{
              state
              | items: insert_item(next_items, grand_parent_path, parent_index + 1, removed_item)
            }
        end
    end
  end

  @spec delete_selected(term()) :: term()
  def delete_selected(%{selected_id: @home_item_id} = state), do: state

  def delete_selected(%{selected_id: selected_id} = state) do
    items = remove_item(state.items, selected_id)
    %{state | items: items, selected_id: first_item_id(items), draft: nil}
  end

  def drop_selected(state, drag_item_id, target_item_id, _position)
      when drag_item_id in [nil, ""] or target_item_id in [nil, ""] do
    state
  end

  def drop_selected(state, drag_item_id, target_item_id, _position)
      when drag_item_id == target_item_id,
      do: state

  @spec drop_selected(term(), term(), term(), term()) :: term()
  def drop_selected(state, drag_item_id, target_item_id, position) do
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
        %{
          state
          | items: insert_item(next_items, target_path, 0, dragged_item),
            selected_id: dragged_item.item_id
        }

      _other ->
        state
    end
  end

  defp insert_dropped_item(state, next_items, dragged_item, target_path, "before") do
    parent_path = Enum.drop(target_path, -1)
    index = List.last(target_path)

    %{
      state
      | items: insert_item(next_items, parent_path, index, dragged_item),
        selected_id: dragged_item.item_id
    }
  end

  defp insert_dropped_item(state, next_items, dragged_item, target_path, _position) do
    parent_path = Enum.drop(target_path, -1)
    index = List.last(target_path) + 1

    %{
      state
      | items: insert_item(next_items, parent_path, index, dragged_item),
        selected_id: dragged_item.item_id
    }
  end
end
