defmodule BDS.Frontmatter do
  @moduledoc false

  alias BDS.Persistence

  @list_item_prefix "  - "
  @block_scalar_indent "  "

  def serialize_document(fields, body) when is_list(fields) do
    frontmatter =
      fields
      |> Enum.flat_map(&serialize_field/1)
      |> Enum.join("\n")

    ["---", frontmatter, "---", body || "", ""]
    |> Enum.join("\n")
  end

  def parse_document(contents) when is_binary(contents) do
    case String.split(contents, "\n---\n", parts: 2) do
      [frontmatter_with_marker, body] ->
        frontmatter = String.replace_prefix(frontmatter_with_marker, "---\n", "")

        {:ok,
         %{
           fields: parse_frontmatter(frontmatter),
           body: String.trim_trailing(body, "\n")
         }}

      _parts ->
        {:error, :invalid_frontmatter}
    end
  end

  defp serialize_field({_key, nil}), do: []
  defp serialize_field({_key, ""}), do: []
  defp serialize_field({_key, false}), do: []

  defp serialize_field({key, true}) do
    ["#{key}: true"]
  end

  defp serialize_field({key, values}) when is_list(values) do
    ["#{key}:" | Enum.map(values, &"  - #{serialize_scalar(nil, &1)}")]
  end

  defp serialize_field({key, value}) when is_atom(value) do
    ["#{key}: #{Atom.to_string(value)}"]
  end

  defp serialize_field({key, value}) when is_integer(value) do
    rendered =
      if timestamp_key?(key) do
        Persistence.timestamp_to_iso8601(value)
      else
        Integer.to_string(value)
      end

    if timestamp_key?(key) do
      ["#{key}: '#{rendered}'"]
    else
      ["#{key}: #{rendered}"]
    end
  end

  defp serialize_field({key, value}) do
    ["#{key}: #{serialize_scalar(key, value)}"]
  end

  defp parse_frontmatter(frontmatter) do
    frontmatter
    |> String.split("\n", trim: true)
    |> parse_lines(%{})
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

        if block_scalar_indicator?(raw_value) do
          {value_lines, remaining} = take_block_scalar_lines(rest, [])
          value = parse_scalar(key, parse_block_scalar(raw_value, value_lines))
          parse_lines(remaining, Map.put(acc, key, value))
        else
          parse_lines(rest, Map.put(acc, key, parse_scalar(key, raw_value)))
        end

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

  defp take_block_scalar_lines([line | rest], lines) do
    if String.starts_with?(line, @block_scalar_indent) do
      take_block_scalar_lines(rest, [String.replace_prefix(line, @block_scalar_indent, "") | lines])
    else
      {Enum.reverse(lines), [line | rest]}
    end
  end

  defp take_block_scalar_lines([], lines), do: {Enum.reverse(lines), []}

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

  defp block_scalar_indicator?(value) do
    trimmed = String.trim(value)
    String.starts_with?(trimmed, ">") or String.starts_with?(trimmed, "|")
  end

  defp parse_block_scalar(indicator, lines) do
    trimmed = String.trim(indicator)

    cond do
      String.starts_with?(trimmed, ">") -> Enum.join(lines, " ")
      String.starts_with?(trimmed, "|") -> Enum.join(lines, "\n")
      true -> Enum.join(lines, "\n")
    end
  end

  defp serialize_scalar(_key, value) when is_boolean(value) do
    if(value, do: "true", else: "false")
  end

  defp serialize_scalar(_key, value) when is_atom(value) do
    Atom.to_string(value)
  end

  defp serialize_scalar(key, value) when is_integer(value) do
    if is_binary(key) and timestamp_key?(key) do
      "'#{Persistence.timestamp_to_iso8601(value)}'"
    else
      Integer.to_string(value)
    end
  end

  defp serialize_scalar(_key, value) do
    value
    |> to_string()
    |> maybe_quote_string()
  end

  defp maybe_quote_string(value) do
    if Regex.match?(~r/^[\p{L}\p{N} ._\/-]+$/u, value) do
      value
    else
      escaped =
        value
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")
        |> String.replace("\n", "\\n")

      "\"#{escaped}\""
    end
  end

  defp timestamp_key?(key) do
    rendered = to_string(key)
    String.ends_with?(rendered, "_at") or String.ends_with?(rendered, "At")
  end
end
