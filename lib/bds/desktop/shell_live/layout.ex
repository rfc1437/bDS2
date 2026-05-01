defmodule BDS.Desktop.ShellLive.Layout do
  @moduledoc false

  alias BDS.UI.Workbench

  def sync(workbench, params) do
    workbench
    |> maybe_set_sidebar_width(Map.get(params, "sidebar_width"))
    |> maybe_set_assistant_width(Map.get(params, "assistant_sidebar_width"))
  end

  def resize(workbench, "sidebar", width) do
    workbench
    |> Workbench.set_sidebar_width(parse_width(width))
    |> Map.put(:sidebar_visible, true)
  end

  def resize(workbench, "assistant", width) do
    workbench
    |> Workbench.set_assistant_sidebar_width(parse_width(width))
    |> Map.put(:assistant_sidebar_visible, true)
  end

  def resize(workbench, _target, _width), do: workbench

  def ignore_shortcut?(params) do
    Map.get(params, "alt", false) or
      Map.get(params, "contentEditable", false) or
      Map.get(params, "content_editable", false) or
      Map.get(params, "tag") in ["INPUT", "TEXTAREA", "SELECT"] or
      Map.get(params, :tag) in ["INPUT", "TEXTAREA", "SELECT"]
  end

  defp maybe_set_sidebar_width(workbench, nil), do: workbench
  defp maybe_set_sidebar_width(workbench, width),
    do: Workbench.set_sidebar_width(workbench, parse_width(width))

  defp maybe_set_assistant_width(workbench, nil), do: workbench

  defp maybe_set_assistant_width(workbench, width),
    do: Workbench.set_assistant_sidebar_width(workbench, parse_width(width))

  defp parse_width(width) when is_integer(width), do: width

  defp parse_width(width) when is_binary(width) do
    case Integer.parse(width) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp parse_width(_), do: 0
end
