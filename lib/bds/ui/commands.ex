defmodule BDS.UI.Commands do
  @moduledoc false

  alias BDS.UI.MenuBar

  def handle_shortcut(state, shortcut) when is_map(shortcut) do
    key = shortcut |> Map.get(:key, Map.get(shortcut, "key", "")) |> String.downcase()
    primary = Map.get(shortcut, :meta, false) or Map.get(shortcut, :ctrl, false)

    cond do
      primary and key == "b" -> MenuBar.execute(state, :toggle_sidebar)
      primary and key == "w" -> MenuBar.execute(state, :close_tab)
      true -> state
    end
  end
end