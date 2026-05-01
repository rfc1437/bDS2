defmodule BDS.Desktop.ShellLive.ChatEditor.ToolSurfaces do
  @moduledoc false

  alias BDS.Desktop.ShellData

  @render_tool_names MapSet.new([
                       "render_card",
                       "render_chart",
                       "render_form",
                       "render_list",
                       "render_metric",
                       "render_mindmap",
                       "render_table",
                       "render_tabs"
                     ])

  def render_tool?(name) when is_binary(name), do: MapSet.member?(@render_tool_names, name)
  def render_tool?(_name), do: false

  def build_render_surfaces(tool_calls, message_id, assigns) do
    tool_calls
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool_call, index} ->
      case build_render_surface(tool_call, "#{message_id}-surface-#{index}", assigns) do
        nil -> []
        surface -> [surface]
      end
    end)
  end

  def build_render_surface(%{name: name, arguments: arguments}, surface_id, assigns) do
    if MapSet.member?(@render_tool_names, name) do
      do_build_render_surface(name, arguments || %{}, surface_id, assigns)
    end
  end

  def normalize_tool_surface(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"type" => type} = decoded} ->
        %{
          type: type,
          title: decoded["title"],
          columns: List.wrap(decoded["columns"]),
          rows: Enum.map(List.wrap(decoded["rows"]), &List.wrap/1),
          fields: List.wrap(decoded["fields"]),
          data: decoded
        }

      _other ->
        nil
    end
  end

  def normalize_tool_surface(_content), do: nil

  defp do_build_render_surface("render_card", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "card",
      title: map_value(arguments, "title"),
      subtitle: map_value(arguments, "subtitle"),
      body: map_value(arguments, "body", ""),
      actions: decode_surface_actions(map_value(arguments, "actions", []))
    }
  end

  defp do_build_render_surface("render_table", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "table",
      title: map_value(arguments, "title"),
      columns: stringify_list(map_value(arguments, "columns", [])),
      rows: Enum.map(List.wrap(map_value(arguments, "rows", [])), &stringify_list/1)
    }
  end

  defp do_build_render_surface("render_chart", arguments, surface_id, _assigns) do
    series =
      map_value(arguments, "series", [])
      |> List.wrap()
      |> Enum.map(fn entry ->
        %{
          label: map_value(entry, "label", translated("chat.role.assistant")),
          value: numeric_value(map_value(entry, "value", 0)),
          segments: List.wrap(map_value(entry, "segments", []))
        }
      end)

    %{
      id: surface_id,
      type: "chart",
      title: map_value(arguments, "title"),
      chart_type: map_value(arguments, "chart_type", "bar"),
      series: series,
      max_value: Enum.max([0 | Enum.map(series, & &1.value)])
    }
  end

  defp do_build_render_surface("render_metric", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "metric",
      label: map_value(arguments, "label", "Metric"),
      value: map_value(arguments, "value", "")
    }
  end

  defp do_build_render_surface("render_list", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "list",
      title: map_value(arguments, "title"),
      items: stringify_list(map_value(arguments, "items", []))
    }
  end

  defp do_build_render_surface("render_mindmap", arguments, surface_id, _assigns) do
    nodes =
      arguments
      |> map_value("nodes", [])
      |> List.wrap()
      |> Enum.map(fn node ->
        %{
          id: map_value(node, "id"),
          label: map_value(node, "label", "Node"),
          children: stringify_list(map_value(node, "children", []))
        }
      end)

    %{
      id: surface_id,
      type: "mindmap",
      title: map_value(arguments, "title"),
      nodes: nodes
    }
  end

  defp do_build_render_surface("render_form", arguments, surface_id, assigns) do
    stored_fields = Map.get(assigns.chat_editor_surface_data, surface_id, %{})

    fields =
      arguments
      |> map_value("fields", [])
      |> List.wrap()
      |> Enum.map(fn field ->
        key = map_value(field, "key", "field")

        %{
          key: key,
          label: map_value(field, "label", key),
          input_type: map_value(field, "inputType") || map_value(field, "input_type", "text"),
          placeholder: map_value(field, "placeholder"),
          value: Map.get(stored_fields, key, map_value(field, "defaultValue") || map_value(field, "default_value")),
          options: decode_surface_options(map_value(field, "options", [])),
          required?: truthy?(map_value(field, "required", false))
        }
      end)

    %{
      id: surface_id,
      type: "form",
      title: map_value(arguments, "title"),
      fields: fields,
      submit_label: map_value(arguments, "submitLabel") || map_value(arguments, "submit_label", translated("chat.stop")),
      submit_action: map_value(arguments, "submitAction") || map_value(arguments, "submit_action", "submitForm")
    }
  end

  defp do_build_render_surface("render_tabs", arguments, surface_id, assigns) do
    tabs =
      arguments
      |> map_value("tabs", [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {tab, tab_index} ->
        %{
          label: map_value(tab, "label", "Tab #{tab_index + 1}"),
          content:
            tab
            |> map_value("content", [])
            |> List.wrap()
            |> Enum.with_index()
            |> Enum.map(fn {content, content_index} ->
              build_tab_surface(content, "#{surface_id}-tab-#{tab_index}-#{content_index}", assigns)
            end)
        }
      end)

    %{
      id: surface_id,
      type: "tabs",
      title: map_value(arguments, "title"),
      tabs: tabs,
      selected_index: Map.get(assigns.chat_editor_surface_tabs, surface_id, 0)
    }
  end

  defp do_build_render_surface(_name, arguments, surface_id, _assigns) do
    %{id: surface_id, type: "json", raw: arguments}
  end

  defp build_tab_surface(%{} = content, surface_id, assigns) do
    type = map_value(content, "type", "text")

    case type do
      render_type when render_type in ["card", "chart", "form", "list", "metric", "mindmap", "table", "tabs"] ->
        do_build_render_surface("render_#{render_type}", Map.delete(content, "type"), surface_id, assigns)

      "text" ->
        %{id: surface_id, type: "text", body: map_value(content, "body") || map_value(content, "text", "")}

      _other ->
        %{id: surface_id, type: "json", raw: content}
    end
  end

  defp build_tab_surface(content, surface_id, _assigns) do
    %{id: surface_id, type: "text", body: to_string(content || "")}
  end

  defp decode_surface_actions(actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      %{
        label: map_value(action, "label", translated("chat.openSettings")),
        action: map_value(action, "action", "openSettings"),
        payload: map_value(action, "payload", %{})
      }
    end)
  end

  defp decode_surface_actions(_actions), do: []

  defp decode_surface_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        label: map_value(option, "label", ""),
        value: map_value(option, "value", "")
      }
    end)
  end

  defp decode_surface_options(_options), do: []

  defp stringify_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp stringify_list(value), do: List.wrap(value) |> Enum.map(&to_string/1)

  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> 0
    end
  end

  defp numeric_value(_value), do: 0

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp truthy?(value) when value in [true, "true", 1, "1", "on"], do: true
  defp truthy?(_value), do: false

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
