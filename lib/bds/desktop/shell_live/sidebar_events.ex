defmodule BDS.Desktop.ShellLive.SidebarEvents do
  @moduledoc false

  alias BDS.Desktop.ShellLive.SidebarState, as: ShellSidebarState

  @spec handle(Phoenix.LiveView.Socket.t(), String.t(), map(), (Phoenix.LiveView.Socket.t(),
                                                                term() ->
                                                                  Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(socket, event, params, reload)

  def handle(socket, "toggle_sidebar_filters", _params, reload) do
    socket =
      ShellSidebarState.put_filter_panel_state(socket, fn state ->
        if state.visible do
          %{state | visible: false}
        else
          %{
            visible: true,
            archive_collapsed: true,
            tags_collapsed: true,
            categories_collapsed: true,
            expanded_year: nil
          }
        end
      end)

    {:noreply, reload.(socket, socket.assigns.workbench)}
  end

  def handle(socket, "toggle_sidebar_archive", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state | archive_collapsed: not state.archive_collapsed}
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "toggle_sidebar_tags", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state | tags_collapsed: not state.tags_collapsed}
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "toggle_sidebar_categories", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state | categories_collapsed: not state.categories_collapsed}
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "update_sidebar_search", %{"sidebar_filters" => params}, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       Map.put(
         filters,
         :search,
         ShellSidebarState.normalize_filter_string(Map.get(params, "search"))
       )
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "clear_sidebar_search", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :search, nil) end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "clear_sidebar_tags", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :tags, []) end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "clear_sidebar_categories", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :categories, []) end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "toggle_sidebar_tag", %{"tag" => tag}, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       ShellSidebarState.toggle_filter_value(filters, :tags, tag)
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "toggle_sidebar_category", %{"category" => category}, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       ShellSidebarState.toggle_filter_value(filters, :categories, category)
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "select_sidebar_year", %{"year" => year}, reload) do
    parsed_year = ShellSidebarState.parse_optional_integer(year)

    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{
         state
         | archive_collapsed: false,
           expanded_year: if(state.expanded_year == parsed_year, do: nil, else: parsed_year)
       }
     end)
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:year, parsed_year)
       |> Map.put(:month, nil)
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "select_sidebar_month", %{"year" => year, "month" => month}, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{
         state
         | archive_collapsed: false,
           expanded_year: ShellSidebarState.parse_optional_integer(year)
       }
     end)
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:year, ShellSidebarState.parse_optional_integer(year))
       |> Map.put(:month, ShellSidebarState.parse_optional_integer(month))
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "clear_sidebar_month", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filter_panel_state(fn state ->
       %{state | archive_collapsed: false}
     end)
     |> ShellSidebarState.put_filters(fn filters ->
       filters |> Map.put(:year, nil) |> Map.put(:month, nil)
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "clear_sidebar_filters", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       filters
       |> Map.put(:search, nil)
       |> Map.put(:year, nil)
       |> Map.put(:month, nil)
       |> Map.put(:tags, [])
       |> Map.put(:categories, [])
       |> Map.put(
         :display_limit,
         ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data)
       )
     end)
     |> reload.(socket.assigns.workbench)}
  end

  def handle(socket, "load_more_sidebar", _params, reload) do
    {:noreply,
     socket
     |> ShellSidebarState.put_filters(fn filters ->
       Map.update(
         filters,
         :display_limit,
         ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data),
         &(&1 + ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data))
       )
     end)
     |> reload.(socket.assigns.workbench)}
  end
end
