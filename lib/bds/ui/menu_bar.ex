defmodule BDS.UI.MenuBar do
  @moduledoc false

  alias BDS.UI.Workbench

  def default_groups(opts \\ []) do
    dev_mode? = Keyword.get(opts, :dev_mode?, false)

    [
      %{id: :app, items: [%{id: :about}, %{id: :settings}]},
      %{id: :file, items: [%{id: :new_post}, %{id: :new_page}, %{id: :close_tab}]},
      %{id: :edit, items: [%{id: :undo}, %{id: :redo}]},
      %{id: :view, items: view_items(dev_mode?)},
      %{id: :window, items: [%{id: :minimize}, %{id: :zoom}]},
      %{id: :help, items: [%{id: :documentation}, %{id: :api_documentation}]}
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
    base = [
      %{id: :toggle_sidebar},
      %{id: :toggle_panel},
      %{id: :toggle_assistant_sidebar}
    ]

    if dev_mode?, do: base ++ [%{id: :toggle_dev_tools}], else: base
  end
end