defmodule BDS.Sidecar do
  @moduledoc false

  alias BDS.Persistence

  @list_item_prefix "  - "
  @document_marker "---"
  @always_quoted_keys MapSet.new(["originalName", "title", "alt", "caption", "author"])

  def serialize_document(fields) when is_list(fields) do
    serialized_fields =
      fields
      |> Enum.flat_map(&serialize_field/1)
      |> Enum.join("\n")

    [@document_marker, serialized_fields, @document_marker]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
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
    serialized_values = values |> Enum.map(&serialize_inline_list_scalar/1) |> Enum.join(", ")
    ["#{key}: [#{serialized_values}]"]
  end

  defp serialize_field({key, value}) when is_boolean(value) do
    ["#{key}: #{if(value, do: "true", else: "false")}"]
  end

  defp serialize_field({key, value}) when is_integer(value) do
    rendered =
      if timestamp_key?(key) do
        Persistence.timestamp_to_iso8601(value)
      else
        Integer.to_string(value)
      end

    ["#{key}: #{rendered}"]
  end

  defp serialize_field({key, value}) do
    ["#{key}: #{serialize_scalar(key, value)}"]
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
        parse_lines(rest, Map.put(acc, key, parse_scalar(key, raw_value)))

      true ->
        parse_lines(rest, acc)
    end
  end

  defp take_list_items([line | rest], items) do
    if String.starts_with?(line, @list_item_prefix) do
      value = line |> String.replace_prefix(@list_item_prefix, "") |> then(&parse_scalar(nil, &1))
      take_list_items(rest, [value | items])
    else
      {items, [line | rest]}
    end
  end

  defp take_list_items([], items), do: {items, []}

  defp parse_scalar(key, value) when is_binary(key) and is_binary(value) do
    trimmed = String.trim(value)
    parsed = parse_generic_scalar(trimmed)

    cond do
      timestamp_key?(key) ->
        if is_binary(parsed) do
          Persistence.parse_timestamp(parsed) || parsed
        else
          parsed
        end

      true ->
        parsed
    end
  end

  defp parse_scalar(nil, value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_generic_scalar()
  end

  defp parse_generic_scalar("true"), do: true
  defp parse_generic_scalar("false"), do: false
  defp parse_generic_scalar("[]"), do: []

  defp parse_generic_scalar("[" <> _rest = value) do
    parse_inline_list(value)
  end

  defp parse_generic_scalar(value) do
    if Regex.match?(~r/^-?\d+$/, value) do
      String.to_integer(value)
    else
      parse_string(value)
    end
  end

  defp parse_string("\"" <> rest) do
    rest
    |> String.trim_trailing("\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp parse_string("'" <> rest) do
    rest
    |> String.trim_trailing("'")
    |> String.replace("\\n", "\n")
    |> String.replace("\\'", "'")
    |> String.replace("\\\\", "\\")
  end

  defp parse_string(value), do: value

  defp serialize_scalar(_key, value) when is_boolean(value) do
    if(value, do: "true", else: "false")
  end

  defp serialize_scalar(key, value) when is_integer(value) do
    if is_binary(key) and timestamp_key?(key) do
      Persistence.timestamp_to_iso8601(value)
    else
      Integer.to_string(value)
    end
  end

  defp serialize_scalar(key, value) do
    string_value = to_string(value)

    if is_binary(key) and MapSet.member?(@always_quoted_keys, key) do
      quote_string(string_value)
    else
      maybe_quote_string(string_value)
    end
  end

  defp serialize_inline_list_scalar(value) when is_binary(value), do: quote_string(value)
  defp serialize_inline_list_scalar(value), do: serialize_scalar(nil, value)

  defp parse_inline_list(value) do
    inner =
      value
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim()

    if inner == "" do
      []
    else
      parse_inline_list_items(inner)
    end
  end

  defp parse_inline_list_items(inner) do
    if String.contains?(inner, "\"") or String.contains?(inner, "'") do
      Regex.scan(~r/"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)'/, inner, capture: :all_but_first)
      |> Enum.map(fn captures ->
        captures
        |> Enum.find(&(&1 != ""))
        |> parse_inline_string_item()
      end)
    else
      inner
      |> String.split(",", trim: true)
      |> Enum.map(&(String.trim(&1) |> parse_scalar(nil)))
    end
  end

  defp parse_inline_string_item(nil), do: ""

  defp parse_inline_string_item(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\'", "'")
    |> String.replace("\\\\", "\\")
  end

  defp maybe_quote_string(value) do
    if Regex.match?(~r/^[\p{L}\p{N} ._\/-]+$/u, value) do
      value
    else
      quote_string(value)
    end
  end

  defp quote_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  defp timestamp_key?(key) do
    rendered = to_string(key)
    String.ends_with?(rendered, "_at") or String.ends_with?(rendered, "At")
  end
end
