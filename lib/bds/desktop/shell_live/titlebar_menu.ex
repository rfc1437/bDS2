defmodule BDS.Desktop.ShellLive.TitlebarMenu do
  @moduledoc false

  use Phoenix.Component
  alias BDS.Desktop.MenuBar, as: DesktopMenuBar

  @spec groups() :: [map()]
  def groups do
    DesktopMenuBar.groups(dev_mode?: Application.get_env(:bds, :dev_routes, false))
  end

  @spec dropdown_items(map()) :: [map()]
  def dropdown_items(group) do
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

  @spec item_active?(map(), map(), non_neg_integer() | nil) :: boolean()
  def item_active?(group, item, current_index) do
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

  @spec active_group(map()) :: map() | nil
  def active_group(assigns) do
    Enum.find(assigns.menu_groups || [], fn group ->
      Atom.to_string(group.id) == assigns.titlebar_menu_group
    end)
  end

  @spec active_items(map()) :: [map()]
  def active_items(assigns) do
    assigns
    |> active_group()
    |> case do
      nil -> []
      group -> Enum.reject(group.items, &Map.get(&1, :separator, false))
    end
  end

  @spec open(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, group) do
    socket
    |> assign(:titlebar_menu_group, group)
    |> assign(:titlebar_menu_item_index, nil)
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> assign(:titlebar_menu_group, nil)
    |> assign(:titlebar_menu_item_index, nil)
  end

  @spec toggle(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle(socket, group) do
    if socket.assigns.titlebar_menu_group == group do
      close(socket)
    else
      open(socket, group)
    end
  end

  @spec hover(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def hover(socket, group) do
    if socket.assigns.titlebar_menu_group do
      open(socket, group)
    else
      socket
    end
  end

  @doc """
  Handle a keydown event on an open titlebar menu. `invoke_fun` is called
  with the action id (string) when the user activates an item.
  """
  @spec handle_keydown(Phoenix.LiveView.Socket.t(), String.t(), (Phoenix.LiveView.Socket.t(),
                                                                 String.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def handle_keydown(socket, key, invoke_fun) do
    if socket.assigns.titlebar_menu_group do
      case key do
        "Escape" -> close(socket)
        "ArrowRight" -> rotate_group(socket, 1)
        "ArrowLeft" -> rotate_group(socket, -1)
        "ArrowDown" -> advance_item_index(socket, 1)
        "ArrowUp" -> advance_item_index(socket, -1)
        "Home" -> set_first_item_index(socket)
        "End" -> set_last_item_index(socket)
        "Enter" -> invoke_active_item(socket, invoke_fun)
        " " -> invoke_active_item(socket, invoke_fun)
        _other -> socket
      end
    else
      socket
    end
  end

  defp rotate_group(socket, offset) do
    groups = socket.assigns.menu_groups || []
    current_group = socket.assigns.titlebar_menu_group

    current_index =
      Enum.find_index(groups, fn group -> Atom.to_string(group.id) == current_group end)

    if is_nil(current_index) or groups == [] do
      socket
    else
      next_index = rem(current_index + offset + length(groups), length(groups))
      next_group = Enum.at(groups, next_index)
      open(socket, Atom.to_string(next_group.id))
    end
  end

  defp advance_item_index(socket, offset) do
    items = active_items(socket.assigns)
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

  defp set_last_item_index(socket) do
    items = active_items(socket.assigns)

    if items == [] do
      socket
    else
      assign(socket, :titlebar_menu_item_index, length(items) - 1)
    end
  end

  defp set_first_item_index(socket) do
    items = active_items(socket.assigns)

    if items == [] do
      socket
    else
      assign(socket, :titlebar_menu_item_index, 0)
    end
  end

  defp invoke_active_item(socket, invoke_fun) do
    items = active_items(socket.assigns)

    case Enum.at(items, socket.assigns[:titlebar_menu_item_index]) do
      %{id: id} ->
        socket
        |> close()
        |> invoke_fun.(Atom.to_string(id))

      _other ->
        socket
    end
  end
end
