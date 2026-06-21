defmodule BDS.Desktop.ShellLive.SidebarEvents do
  @moduledoc false

  alias BDS.Desktop.ShellLive.SidebarState, as: ShellSidebarState

  @event_handlers %{
    "toggle_sidebar_filters" => :toggle_sidebar_filters,
    "toggle_sidebar_archive" => :toggle_sidebar_archive,
    "toggle_sidebar_tags" => :toggle_sidebar_tags,
    "toggle_sidebar_categories" => :toggle_sidebar_categories,
    "update_sidebar_search" => :update_sidebar_search,
    "clear_sidebar_search" => :clear_sidebar_search,
    "clear_sidebar_tags" => :clear_sidebar_tags,
    "clear_sidebar_categories" => :clear_sidebar_categories,
    "toggle_sidebar_tag" => :toggle_sidebar_tag,
    "toggle_sidebar_category" => :toggle_sidebar_category,
    "select_sidebar_year" => :select_sidebar_year,
    "select_sidebar_month" => :select_sidebar_month,
    "clear_sidebar_month" => :clear_sidebar_month,
    "clear_sidebar_filters" => :clear_sidebar_filters,
    "load_more_sidebar" => :load_more_sidebar
  }

  @spec handle(Phoenix.LiveView.Socket.t(), String.t(), map(), (Phoenix.LiveView.Socket.t(),
                                                                term() ->
                                                                  Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(socket, event, params, reload) do
    {:noreply, dispatch(event, socket, params, reload)}
  end

  defp dispatch(event, socket, params, reload) do
    case Map.fetch(@event_handlers, event) do
      {:ok, handler} -> handle_event(handler, socket, params, reload)
      :error -> socket
    end
  end

  defp handle_event(:toggle_sidebar_filters, socket, _params, reload) do
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

    reload.(socket, socket.assigns.workbench)
  end

  defp handle_event(:toggle_sidebar_archive, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filter_panel_state(fn state ->
      %{state | archive_collapsed: not state.archive_collapsed}
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:toggle_sidebar_tags, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filter_panel_state(fn state ->
      %{state | tags_collapsed: not state.tags_collapsed}
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:toggle_sidebar_categories, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filter_panel_state(fn state ->
      %{state | categories_collapsed: not state.categories_collapsed}
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:update_sidebar_search, socket, %{"sidebar_filters" => params}, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters ->
      Map.put(
        filters,
        :search,
        ShellSidebarState.normalize_filter_string(Map.get(params, "search"))
      )
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:clear_sidebar_search, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :search, nil) end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:clear_sidebar_tags, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :tags, []) end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:clear_sidebar_categories, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters -> Map.put(filters, :categories, []) end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:toggle_sidebar_tag, socket, %{"tag" => tag}, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters ->
      ShellSidebarState.toggle_filter_value(filters, :tags, tag)
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:toggle_sidebar_category, socket, %{"category" => category}, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters ->
      ShellSidebarState.toggle_filter_value(filters, :categories, category)
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:select_sidebar_year, socket, %{"year" => year}, reload) do
    parsed_year = ShellSidebarState.parse_optional_integer(year)

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
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:select_sidebar_month, socket, %{"year" => year, "month" => month}, reload) do
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
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:clear_sidebar_month, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filter_panel_state(fn state ->
      %{state | archive_collapsed: false}
    end)
    |> ShellSidebarState.put_filters(fn filters ->
      filters |> Map.put(:year, nil) |> Map.put(:month, nil)
    end)
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:clear_sidebar_filters, socket, _params, reload) do
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
    |> reload.(socket.assigns.workbench)
  end

  defp handle_event(:load_more_sidebar, socket, _params, reload) do
    socket
    |> ShellSidebarState.put_filters(fn filters ->
      Map.update(
        filters,
        :display_limit,
        ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data),
        &(&1 + ShellSidebarState.sidebar_page_size(socket.assigns.sidebar_data))
      )
    end)
    |> reload.(socket.assigns.workbench)
  end
end
