defmodule BDS.Sidecar do
  @moduledoc false

  @list_item_prefix "  - "

  def serialize_document(fields) when is_list(fields) do
    fields
    |> Enum.flat_map(&serialize_field/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  def parse_document(contents) when is_binary(contents) do
    {:ok,
     contents
     |> String.split("\n", trim: true)
     |> parse_lines(%{})}
  end

  defp serialize_field({_key, nil}), do: []
  defp serialize_field({_key, ""}), do: []

  defp serialize_field({key, values}) when is_list(values) do
    ["#{key}:" | Enum.map(values, &"  - #{&1}")]
  end

  defp serialize_field({key, value}) when is_boolean(value) do
    ["#{key}: #{if(value, do: "true", else: "false")}"]
  end

  defp serialize_field({key, value}) do
    ["#{key}: #{value}"]
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    cond do
      String.starts_with?(line, @list_item_prefix) ->
        parse_lines(rest, acc)

      String.ends_with?(line, ":") ->
        key = String.trim_trailing(line, ":")
        {items, remaining} = take_list_items(rest, [])
        parse_lines(remaining, Map.put(acc, key, Enum.reverse(items)))

      String.contains?(line, ": ") ->
        [key, raw_value] = String.split(line, ": ", parts: 2)
        parse_lines(rest, Map.put(acc, key, parse_scalar(raw_value)))

      true ->
        parse_lines(rest, acc)
    end
  end

  defp take_list_items([line | rest], items) do
    if String.starts_with?(line, @list_item_prefix) do
      value = line |> String.replace_prefix(@list_item_prefix, "") |> parse_scalar()
      take_list_items(rest, [value | items])
    else
      {items, [line | rest]}
    end
  end

  defp take_list_items([], items), do: {items, []}

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false

  defp parse_scalar(value) do
    if Regex.match?(~r/^-?\d+$/, value) do
      String.to_integer(value)
    else
      value
    end
  end
end
