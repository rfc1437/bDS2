defmodule BDS.Desktop.MenuBar do
  @moduledoc false

  use Desktop.Menu
  alias Desktop.Window

  def groups(opts \\ []) do
    dev_mode? = Keyword.get(opts, :dev_mode?, false)

    [
      %{id: :app, label: "App", items: [%{id: :about, label: "About"}]},
      %{id: :file, label: "File", items: [%{id: :new_post, label: "New Post"}, %{id: :close_tab, label: "Close Tab"}]},
      %{id: :edit, label: "Edit", items: [%{id: :undo, label: "Undo"}, %{id: :redo, label: "Redo"}]},
      %{id: :view, label: "View", items: view_items(dev_mode?)},
      %{id: :window, label: "Window", items: [%{id: :minimize, label: "Minimize"}]},
      %{id: :help, label: "Help", items: [%{id: :documentation, label: "Documentation"}]}
    ]
  end

  @impl true
  def mount(menu) do
    {:ok,
     Desktop.Menu.assign(
       menu,
       :groups,
       groups(dev_mode?: Application.get_env(:bds, :dev_routes, false))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <menubar>
      <%= for group <- @groups do %>
        <menu label={group.label}>
          <%= for item <- group.items do %>
            <item onclick={Atom.to_string(item.id)}>{item.label}</item>
          <% end %>
        </menu>
      <% end %>
    </menubar>
    """
  end

  @impl true
  def handle_event("quit", menu) do
    Window.quit()
    {:noreply, menu}
  end

  def handle_event(_, menu) do
    {:noreply, menu}
  end

  @impl true
  def handle_info(_, menu) do
    {:noreply, menu}
  end

  defp view_items(dev_mode?) do
    items = [
      %{id: :toggle_sidebar, label: "Toggle Sidebar"},
      %{id: :toggle_panel, label: "Toggle Panel"},
      %{id: :toggle_assistant_sidebar, label: "Toggle Assistant Sidebar"}
    ]

    if dev_mode? do
      items ++ [%{id: :toggle_dev_tools, label: "Toggle Dev Tools"}]
    else
      items
    end
  end
end
