defmodule BDS.Frontmatter do
  @moduledoc false

  def serialize_document(fields, body) when is_list(fields) do
    frontmatter =
      fields
      |> Enum.flat_map(&serialize_field/1)
      |> Enum.join("\n")

    ["---", frontmatter, "---", body || "", ""]
    |> Enum.join("\n")
  end

  defp serialize_field({_key, nil}), do: []
  defp serialize_field({_key, ""}), do: []
  defp serialize_field({_key, false}), do: []

  defp serialize_field({key, true}) do
    ["#{key}: true"]
  end

  defp serialize_field({key, values}) when is_list(values) do
    ["#{key}:" | Enum.map(values, &"  - #{&1}")]
  end

  defp serialize_field({key, value}) do
    ["#{key}: #{value}"]
  end
end