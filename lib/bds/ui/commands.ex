defmodule BDS.UI.Commands do
  @moduledoc false

  alias BDS.UI.MenuBar

  @menu_shortcuts [
    %{id: :new_post, accelerator: "CTRL+N"},
    %{id: :import_media, accelerator: "CTRL+I"},
    %{id: :save, accelerator: "CTRL+S"},
    %{id: :close_tab, accelerator: "CTRL+W", key: "w", primary: true},
    %{id: :quit, accelerator: "CTRL+Q"},
    %{id: :undo, accelerator: "CTRL+Z"},
    %{id: :redo, accelerator: "CTRL+Y"},
    %{id: :cut, accelerator: "CTRL+X"},
    %{id: :copy, accelerator: "CTRL+C"},
    %{id: :paste, accelerator: "CTRL+V"},
    %{id: :select_all, accelerator: "CTRL+A"},
    %{id: :find, accelerator: "CTRL+F"},
    %{id: :replace, accelerator: "CTRL+H"},
    %{id: :edit_preferences, accelerator: "CTRL+,"},
    %{id: :view_posts, accelerator: "CTRL+1", key: "1", primary: true},
    %{id: :view_media, accelerator: "CTRL+2", key: "2", primary: true},
    %{id: :toggle_sidebar, accelerator: "CTRL+B", key: "b", primary: true},
    %{id: :toggle_panel, accelerator: "CTRL+J", key: "j", primary: true},
    %{id: :toggle_assistant_sidebar, accelerator: "CTRL+\\", key: "\\", primary: true},
    %{id: :toggle_dev_tools, accelerator: "CTRL+SHIFT+I"},
    %{id: :publish_selected, accelerator: "CTRL+SHIFT+P"},
    %{id: :preview_post, accelerator: "CTRL+SHIFT+V"},
    %{id: :generate_sitemap, accelerator: "CTRL+R"},
    %{id: :validate_site, accelerator: "CTRL+SHIFT+L"},
    %{id: :upload_site, accelerator: "CTRL+SHIFT+U"}
  ]

  def handle_shortcut(state, shortcut) when is_map(shortcut) do
    key = shortcut |> Map.get(:key, Map.get(shortcut, "key", "")) |> String.downcase()
    primary = Map.get(shortcut, :meta, false) or Map.get(shortcut, :ctrl, false)

    case Enum.find(@menu_shortcuts, &shortcut_match?(&1, key, primary)) do
      %{id: command_id} -> MenuBar.execute(state, command_id)
      nil -> state
    end
  end

  def accelerator_label(command_id) when is_atom(command_id) do
    case Enum.find(@menu_shortcuts, &(&1.id == command_id)) do
      %{accelerator: accelerator} -> accelerator
      nil -> nil
    end
  end

  defp shortcut_match?(%{key: expected_key, primary: expected_primary}, key, primary) do
    key == expected_key and primary == expected_primary
  end

  defp shortcut_match?(_shortcut, _key, _primary), do: false
end
