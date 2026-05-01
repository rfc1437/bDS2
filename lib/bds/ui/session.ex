defmodule BDS.UI.Session do
  @moduledoc false

  alias BDS.BoundedAtoms
  alias BDS.UI.Workbench

  def serialize(state) do
    %{
      "sidebar_visible" => state.sidebar_visible,
      "sidebar_width" => state.sidebar_width,
      "active_view" => Atom.to_string(state.active_view),
      "assistant_sidebar_visible" => state.assistant_sidebar_visible,
      "assistant_sidebar_width" => state.assistant_sidebar_width,
      "panel" => %{
        "visible" => state.panel.visible,
        "active_tab" => Atom.to_string(state.panel.active_tab)
      },
      "tabs" =>
        Enum.map(state.tabs, fn tab ->
          %{
            "type" => Atom.to_string(tab.type),
            "id" => tab.id,
            "is_transient" => tab.is_transient
          }
        end),
      "active_tab" => encode_tab_ref(state.active_tab),
      "dirty_tabs" => Enum.map(state.dirty_tabs, &encode_tab_ref/1)
    }
  end

  def restore(payload) when is_map(payload) do
    state =
      Workbench.new(
        sidebar_visible: Map.get(payload, "sidebar_visible", true),
        sidebar_width: Map.get(payload, "sidebar_width", 280),
        active_view: BoundedAtoms.sidebar_view(Map.get(payload, "active_view"), :posts),
        assistant_sidebar_visible: Map.get(payload, "assistant_sidebar_visible", false),
        assistant_sidebar_width: Map.get(payload, "assistant_sidebar_width", 360),
        panel_visible: get_in(payload, ["panel", "visible"]) || false,
        panel_tab:
          BoundedAtoms.panel_tab(get_in(payload, ["panel", "active_tab"]) || "tasks", :tasks),
        dirty_tabs: Enum.map(Map.get(payload, "dirty_tabs", []), &decode_tab_ref/1)
      )

    tabs =
      Enum.map(Map.get(payload, "tabs", []), fn tab ->
        %{
          type: BoundedAtoms.editor_route(Map.get(tab, "type", "post"), :post),
          id: Map.get(tab, "id"),
          is_transient: Map.get(tab, "is_transient", false)
        }
      end)

    active_tab = decode_tab_ref(Map.get(payload, "active_tab"))

    %{state | tabs: tabs, active_tab: active_tab, editor_route: active_route(active_tab)}
  end

  defp encode_tab_ref(nil), do: nil
  defp encode_tab_ref({type, id}), do: %{"type" => Atom.to_string(type), "id" => id}

  defp decode_tab_ref(nil), do: nil

  defp decode_tab_ref(%{"type" => type, "id" => id}),
    do: {BoundedAtoms.editor_route(type, :post), id}

  defp active_route(nil), do: :dashboard
  defp active_route({type, _id}), do: type
end
