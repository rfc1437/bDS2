defmodule BDS.Desktop.ShellLive.ChatEditor.ToolTracking do
  @moduledoc false

  @tool_args_max_length 30

  def tool_call_name(tool_call) when is_map(tool_call) do
    BDS.MapUtils.attr(tool_call, :name) || "tool"
  end

  def tool_call_arguments(tool_call) when is_map(tool_call) do
    BDS.MapUtils.attr(tool_call, :arguments) || BDS.MapUtils.attr(tool_call, :args) || %{}
  end

  def normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      arguments = tool_call_arguments(tool_call)

      %{
        id: BDS.MapUtils.attr(tool_call, :id),
        name: tool_call_name(tool_call),
        arguments: arguments,
        args_preview: tool_arguments_preview(arguments),
        complete?: false
      }
    end)
  end

  def normalize_tool_calls(_tool_calls), do: []

  def tool_arguments_preview(arguments) when is_map(arguments) do
    arguments
    |> Enum.map(fn {key, value} -> "#{key}: #{preview_value(value)}" end)
    |> Enum.join(", ")
  end

  def tool_arguments_preview(_arguments), do: ""

  def mark_tool_call_completed(entry, tool_call_id) when is_binary(tool_call_id) do
    update_in(entry.tool_markers, fn markers ->
      Enum.map(markers, fn marker ->
        if marker.id == tool_call_id do
          %{marker | complete?: true}
        else
          marker
        end
      end)
    end)
  end

  def mark_tool_call_completed(entry, _tool_call_id), do: entry

  def tool_markers_from_events(nil), do: []

  def tool_markers_from_events(%{tool_events: tool_events}) do
    Enum.reduce(tool_events || [], [], fn event, markers ->
      case event.type do
        :call ->
          markers ++
            [
              %{
                id: nil,
                name: event.name,
                arguments: event.arguments,
                args_preview: tool_arguments_preview(event.arguments || %{}),
                complete?: false
              }
            ]

        :result ->
          Enum.reverse(markers)
          |> mark_last_matching_complete(event.name)
          |> Enum.reverse()
      end
    end)
  end

  defp mark_last_matching_complete(markers, name) do
    {updated, found?} =
      Enum.map_reduce(markers, false, fn marker, found? ->
        cond do
          found? -> {marker, true}
          marker.name == name and not marker.complete? -> {%{marker | complete?: true}, true}
          true -> {marker, false}
        end
      end)

    if found?, do: updated, else: updated
  end

  defp preview_value(value) when is_binary(value) do
    quoted =
      if String.length(value) > @tool_args_max_length,
        do: String.slice(value, 0, @tool_args_max_length) <> "...",
        else: value

    inspect(quoted)
  end

  defp preview_value(value), do: inspect(value)
end
