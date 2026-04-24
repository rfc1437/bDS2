defmodule BDS.UI.MenuBar do
  @moduledoc false

  alias BDS.UI.Workbench

  def default_groups(opts \\ []) do
    dev_mode? = Keyword.get(opts, :dev_mode?, false)

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
          %{id: :validate_site},
          %{id: :upload_site}
        ]
      },
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

  def execute(state, :toggle_sidebar), do: Workbench.toggle_sidebar(state)
  def execute(state, :toggle_panel), do: Workbench.toggle_panel(state)
  def execute(state, :toggle_assistant_sidebar), do: Workbench.toggle_assistant_sidebar(state)

  def execute(state, :close_tab) do
    case state.active_tab do
      {type, id} -> Workbench.close_tab(state, type, id)
      nil -> state
    end
  end

  def execute(state, _command_id), do: state

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
