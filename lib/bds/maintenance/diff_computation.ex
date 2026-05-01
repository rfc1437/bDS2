defmodule BDS.Maintenance.DiffComputation do
  @moduledoc false

  alias BDS.Persistence

  def build_diff_report(entity_type, entity_id, differences) do
    build_diff_report(entity_type, entity_id, differences, [])
  end

  def build_diff_report(entity_type, entity_id, differences, opts) do
    normalized = Enum.reject(differences, &is_nil/1)

    if normalized == [] do
      nil
    else
      %{
        entity_type: entity_type,
        entity_id: entity_id,
        differences: normalized,
        label: Keyword.get(opts, :label),
        meta_label: Keyword.get(opts, :meta_label)
      }
    end
  end

  def metadata_diff_entity_label(title, slug, fallback_id) do
    blank_to_nil(title) || blank_to_nil(slug) || fallback_id
  end

  def metadata_diff_timestamp_label(nil), do: nil
  def metadata_diff_timestamp_label(timestamp), do: Persistence.timestamp_to_iso8601(timestamp)

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value), do: value

  def diff_field(name, db_value, file_value) do
    if equal_diff_values?(db_value, file_value) do
      nil
    else
      %{name: name, db_value: stringify_value(db_value), file_value: stringify_value(file_value)}
    end
  end

  def equal_diff_values?(left, right) when is_list(left) and is_list(right) do
    normalize_list_diff_values(left) == normalize_list_diff_values(right)
  end

  def equal_diff_values?(left, right) when is_map(left) and is_map(right) do
    normalize_map_diff_values(left) == normalize_map_diff_values(right)
  end

  def equal_diff_values?(left, right), do: stringify_value(left) == stringify_value(right)

  def normalize_list_diff_values(values) do
    values
    |> Enum.map(&stringify_value/1)
    |> Enum.sort()
  end

  def stringify_value(nil), do: ""
  def stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  def stringify_value(value) when is_boolean(value), do: to_string(value)
  def stringify_value(value) when is_integer(value), do: Integer.to_string(value)
  def stringify_value(value) when is_binary(value), do: value

  def stringify_value(value) when is_map(value),
    do: value |> normalize_map_diff_values() |> Jason.encode!()

  def stringify_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &stringify_value/1)

  def stringify_value(value), do: to_string(value)

  def normalize_map_diff_values(values) when is_map(values) do
    values
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_nested_diff_value(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  def normalize_nested_diff_value(value) when is_map(value), do: normalize_map_diff_values(value)

  def normalize_nested_diff_value(value) when is_list(value),
    do: Enum.map(value, &normalize_nested_diff_value/1)

  def normalize_nested_diff_value(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_nested_diff_value(value), do: value
end
