defmodule BDS.Desktop.ShellLive.SidebarState do
  @moduledoc false

  def merge_ui_state(socket, view_id, sidebar_data) do
    filters = Map.get(sidebar_data, :filters)

    if is_map(filters) and Map.get(filters, :enabled) do
      panel_state = filter_panel_state(socket, view_id)

      Map.put(sidebar_data, :filters, Map.merge(filters, %{
        filter_panel_visible: panel_state.visible,
        archive_collapsed: panel_state.archive_collapsed,
        tags_collapsed: panel_state.tags_collapsed,
        categories_collapsed: panel_state.categories_collapsed,
        expanded_year: panel_state.expanded_year
      }))
    else
      sidebar_data
    end
  end

  def put_filter_panel_state(socket, updater) do
    view_id = Atom.to_string(socket.assigns.workbench.active_view)
    state = socket |> filter_panel_state(view_id) |> updater.()
    Phoenix.Component.assign(socket, :sidebar_filter_panels, Map.put(socket.assigns.sidebar_filter_panels, view_id, state))
  end

  def current_filters(socket, view_id) do
    socket.assigns.sidebar_filters_by_view
    |> Map.get(view_id, %{})
    |> normalize_filters(socket.assigns[:sidebar_data])
  end

  def put_filters(socket, updater) do
    view_id = Atom.to_string(socket.assigns.workbench.active_view)
    filters = current_filters(socket, view_id) |> updater.() |> normalize_filters(socket.assigns.sidebar_data)
    Phoenix.Component.assign(socket, :sidebar_filters_by_view, Map.put(socket.assigns.sidebar_filters_by_view, view_id, filters))
  end

  def toggle_filter_value(filters, key, value) do
    values = Map.get(filters, key, [])

    next_values =
      if value in values do
        List.delete(values, value)
      else
        values ++ [value]
      end

    Map.put(filters, key, next_values)
  end

  def normalize_filter_string(nil), do: nil

  def normalize_filter_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def parse_optional_integer(nil), do: nil
  def parse_optional_integer(value) when is_integer(value), do: value

  def parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  def sidebar_page_size(nil), do: 500

  def sidebar_page_size(sidebar_data) do
    sidebar_data
    |> Map.get(:filters, %{})
    |> Map.get(:max_items, 500)
  end

  defp filter_panel_state(socket, view_id) do
    default_state = default_filter_panel_state()

    case Map.get(socket.assigns.sidebar_filter_panels, view_id) do
      state when is_map(state) -> Map.merge(default_state, state)
      visible when is_boolean(visible) -> Map.put(default_state, :visible, visible)
      _other -> default_state
    end
  end

  defp default_filter_panel_state do
    %{
      visible: false,
      archive_collapsed: true,
      tags_collapsed: true,
      categories_collapsed: true,
      expanded_year: nil
    }
  end

  defp normalize_filters(filters, sidebar_data) do
    max_items = sidebar_page_size(sidebar_data)

    %{
      search: normalize_filter_string(Map.get(filters, :search)),
      year: Map.get(filters, :year),
      month: Map.get(filters, :month),
      tags: Map.get(filters, :tags, []),
      categories: Map.get(filters, :categories, []),
      display_limit: max(Map.get(filters, :display_limit, max_items) || max_items, max_items)
    }
  end
end