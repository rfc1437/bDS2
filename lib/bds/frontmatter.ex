defmodule BDS.Frontmatter do
  @moduledoc false

  alias BDS.Persistence

  @list_item_prefix "  - "

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

    ["#{key}: #{rendered}"]
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

    cond do
      timestamp_key?(key) ->
        Persistence.parse_timestamp(trimmed) || parse_generic_scalar(trimmed)

      true ->
        parse_generic_scalar(trimmed)
    end
  end

  defp parse_scalar(nil, value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_generic_scalar()
  end

  defp parse_generic_scalar("true"), do: true
  defp parse_generic_scalar("false"), do: false

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

  defp parse_string(value), do: value

  defp serialize_scalar(_key, value) when is_boolean(value) do
    if(value, do: "true", else: "false")
  end

  defp serialize_scalar(_key, value) when is_atom(value) do
    Atom.to_string(value)
  end

  defp serialize_scalar(key, value) when is_integer(value) do
    if is_binary(key) and timestamp_key?(key) do
      Persistence.timestamp_to_iso8601(value)
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

  defp timestamp_key?(key), do: String.ends_with?(to_string(key), "_at")
end
