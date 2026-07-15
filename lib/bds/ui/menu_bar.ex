defmodule BDS.UI.MenuBar do
  @moduledoc false

  alias BDS.UI.Registry
  alias BDS.UI.Workbench

  @spec default_groups(keyword()) :: [map()]
  def default_groups(opts \\ []) do
    dev_mode? = Keyword.get(opts, :dev_mode?, false)
    window_menu? = Keyword.get(opts, :window_menu?, false)

    [
      %{
        id: :file,
        items: [
          %{id: :new_post},
          %{id: :import_media},
          %{separator: true},
          %{id: :save},
          %{separator: true},
          %{id: :open_in_browser},
          %{separator: true},
          %{id: :connect_server},
          %{id: :disconnect_server},
          %{separator: true},
          %{id: :open_data_folder},
          %{separator: true},
          %{id: :close_tab},
          %{id: :quit}
        ]
      },
      %{
        id: :edit,
        items: [
          %{id: :undo},
          %{id: :redo},
          %{separator: true},
          %{id: :cut},
          %{id: :copy},
          %{id: :paste},
          %{id: :delete},
          %{separator: true},
          %{id: :select_all},
          %{separator: true},
          %{id: :find},
          %{id: :replace},
          %{id: :edit_preferences}
        ]
      },
      %{id: :view, items: view_items(dev_mode?)},
      %{
        id: :blog,
        items: [
          %{id: :publish_selected},
          %{separator: true},
          %{id: :preview_post},
          %{id: :edit_menu},
          %{separator: true},
          %{id: :rebuild_database},
          %{id: :reindex_text},
          %{id: :rebuild_embedding_index},
          %{separator: true},
          %{id: :metadata_diff},
          %{id: :regenerate_calendar},
          %{id: :validate_translations},
          %{id: :fill_missing_translations},
          %{id: :find_duplicates},
          %{separator: true},
          %{id: :generate_sitemap},
          %{id: :force_render_site},
          %{id: :validate_site},
          %{id: :upload_site}
        ]
      }
    ] ++
      window_group(window_menu?) ++
      [
        %{
          id: :help,
          items: [
            %{id: :about},
            %{id: :documentation},
            %{id: :api_documentation},
            %{separator: true},
            %{id: :view_on_github},
            %{id: :report_issue}
          ]
        }
      ]
  end

  # The native macOS menu enables this group; wx's automatic Window menu is
  # disabled because it races the async menubar populate and lands in the
  # wrong position (see BDS.Application.disable_auto_window_menu/0).
  defp window_group(false), do: []

  defp window_group(true) do
    [
      %{
        id: :window,
        items: [
          %{id: :minimize},
          %{id: :zoom},
          %{separator: true},
          %{id: :bring_all_to_front}
        ]
      }
    ]
  end

  @spec execute(Workbench.t(), atom()) :: Workbench.t()
  def execute(state, :toggle_sidebar), do: Workbench.toggle_sidebar(state)
  def execute(state, :toggle_panel), do: Workbench.toggle_panel(state)
  def execute(state, :toggle_assistant_sidebar), do: Workbench.toggle_assistant_sidebar(state)
  def execute(state, :view_posts), do: open_sidebar_view(state, :posts)
  def execute(state, :view_media), do: open_sidebar_view(state, :media)
  def execute(state, :edit_preferences), do: open_singleton_editor(state, :settings)
  def execute(state, :edit_menu), do: open_singleton_editor(state, :menu_editor)
  def execute(state, :documentation), do: open_singleton_editor(state, :documentation)
  def execute(state, :api_documentation), do: open_singleton_editor(state, :api_documentation)

  def execute(state, :close_tab) do
    case state.active_tab do
      {type, id} -> Workbench.close_tab(state, type, id)
      nil -> state
    end
  end

  def execute(state, command_id) when is_atom(command_id) do
    with {:ok, view_id} <- sidebar_view_command(command_id) do
      open_sidebar_view(state, view_id)
    else
      :error ->
        case singleton_editor_command(command_id) do
          {:ok, route_id} -> open_singleton_editor(state, route_id)
          :error -> state
        end
    end
  end

  def execute(state, _command_id), do: state

  defp open_sidebar_view(state, view_id) do
    %{state | active_view: view_id, sidebar_visible: true}
  end

  defp open_singleton_editor(state, route_id) do
    Workbench.open_tab(state, route_id, Atom.to_string(route_id), :pin)
  end

  defp sidebar_view_command(command_id) do
    with "view_" <> suffix <- Atom.to_string(command_id),
         view_id = String.to_existing_atom(suffix),
         %{} <- Registry.sidebar_view(view_id) do
      {:ok, view_id}
    else
      _other -> :error
    end
  end

  defp singleton_editor_command(command_id) do
    with "open_" <> suffix <- Atom.to_string(command_id),
         route_id = String.to_existing_atom(suffix),
         %{singleton: true} <- Registry.editor_route(route_id) do
      {:ok, route_id}
    else
      _other -> :error
    end
  end

  defp view_items(dev_mode?) do
    items = [
      %{id: :view_posts},
      %{id: :view_media},
      %{id: :toggle_sidebar},
      %{id: :toggle_panel},
      %{id: :toggle_assistant_sidebar}
    ]

    items =
      if dev_mode?, do: items ++ [%{id: :toggle_dev_tools}], else: items

    items ++
      [
        %{separator: true},
        %{id: :reload},
        %{id: :force_reload},
        %{separator: true},
        %{id: :reset_zoom},
        %{id: :zoom_in},
        %{id: :zoom_out},
        %{separator: true},
        %{id: :toggle_full_screen}
      ]
  end
end
