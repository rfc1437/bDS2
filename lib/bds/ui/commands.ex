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
    %{id: :edit_preferences, accelerator: "CTRL+,", key: ",", primary: true},
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

  @spec handle_shortcut(BDS.UI.Workbench.t(), map()) :: BDS.UI.Workbench.t()
  def handle_shortcut(state, shortcut) when is_map(shortcut) do
    case command_for_shortcut(shortcut) do
      nil -> state
      command_id -> MenuBar.execute(state, command_id)
    end
  end

  @spec command_for_shortcut(map()) :: atom() | nil
  def command_for_shortcut(shortcut) when is_map(shortcut) do
    key = shortcut |> BDS.MapUtils.attr(:key, "") |> String.downcase()

    primary =
      BDS.MapUtils.attr(shortcut, :meta, false) or
        BDS.MapUtils.attr(shortcut, :ctrl, false)

    shift = BDS.MapUtils.attr(shortcut, :shift, false)
    alt = BDS.MapUtils.attr(shortcut, :alt, false)

    case Enum.find(@menu_shortcuts, &shortcut_match?(&1, key, primary, shift, alt)) do
      %{id: command_id} -> command_id
      nil -> nil
    end
  end

  @spec client_shortcuts() :: [map()]
  def client_shortcuts do
    @menu_shortcuts
    |> Enum.filter(&Map.has_key?(&1, :key))
    |> Enum.map(fn shortcut ->
      %{
        key: shortcut.key,
        primary: Map.get(shortcut, :primary, false),
        shift: Map.get(shortcut, :shift, false),
        alt: Map.get(shortcut, :alt, false)
      }
    end)
  end

  @spec accelerator_label(atom()) :: String.t() | nil
  def accelerator_label(command_id) when is_atom(command_id) do
    case Enum.find(@menu_shortcuts, &(&1.id == command_id)) do
      %{accelerator: accelerator} -> accelerator
      nil -> nil
    end
  end

  defp shortcut_match?(%{key: expected_key} = shortcut, key, primary, shift, alt) do
    key == expected_key and
      primary == Map.get(shortcut, :primary, false) and
      shift == Map.get(shortcut, :shift, false) and
      alt == Map.get(shortcut, :alt, false)
  end

  defp shortcut_match?(_shortcut, _key, _primary, _shift, _alt), do: false
end
