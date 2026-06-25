defmodule BDS.Desktop.ShellLive.UrlState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.BoundedAtoms
  alias BDS.Desktop.ShellLive.{SocketState, TabHelpers}
  alias BDS.UI.Workbench

  def push(socket) do
    workbench = socket.assigns.workbench

    params =
      %{}
      |> put_url_view(workbench.active_view)
      |> put_url_tab(workbench.active_tab)

    query = URI.encode_query(params)
    path = if query == "", do: "/", else: "/?" <> query

    Phoenix.LiveView.push_event(socket, "url-state", %{path: path})
  end

  def apply_params(socket, params) when is_map(params) and map_size(params) > 0 do
    workbench = socket.assigns.workbench

    workbench = apply_url_view(workbench, Map.get(params, "view"))
    workbench = apply_url_tab(workbench, Map.get(params, "tab"))

    if workbench == socket.assigns.workbench do
      socket
    else
      tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})

      socket
      |> assign(:tab_meta, tab_meta)
      |> SocketState.refresh_sidebar(workbench)
    end
  end

  def apply_params(socket, _params), do: socket

  defp put_url_view(params, :posts), do: params
  defp put_url_view(params, view), do: Map.put(params, "view", Atom.to_string(view))

  defp put_url_tab(params, nil), do: params
  defp put_url_tab(params, {type, id}), do: Map.put(params, "tab", Atom.to_string(type) <> ":" <> id)

  defp apply_url_view(workbench, nil), do: workbench

  defp apply_url_view(workbench, view_str) do
    view = BoundedAtoms.sidebar_view(view_str, nil)

    if view && view != workbench.active_view do
      Workbench.click_activity(workbench, view)
    else
      workbench
    end
  end

  defp apply_url_tab(workbench, nil), do: workbench

  defp apply_url_tab(workbench, tab_str) do
    case String.split(tab_str, ":", parts: 2) do
      [type_str, id] ->
        type = BoundedAtoms.editor_route(type_str, nil)

        if type && workbench.active_tab != {type, id} do
          Workbench.open_tab(workbench, type, id, :preview)
        else
          workbench
        end

      _ ->
        workbench
    end
  end
end
