defmodule BDS.Desktop.ShellLive.PostEditor.ListValues do
  @moduledoc false

  alias BDS.{Metadata, Tags}
  require Logger

  @spec field_key(term()) :: term()
  def field_key(:tags), do: "tags"
  def field_key(:categories), do: "categories"

  @spec tag_values(term()) :: term()
  def tag_values(form), do: csv_to_list(Map.get(form, "tags", ""))
  @spec category_values(term()) :: term()
  def category_values(form), do: csv_to_list(Map.get(form, "categories", ""))

  @spec tag_suggestions(term(), term(), term()) :: term()
  def tag_suggestions(form, options, query) do
    selected = MapSet.new(tag_values(form))
    filter_suggestions(options, query, fn option -> option.name end, selected)
  end

  @spec tag_chips(term(), term()) :: term()
  def tag_chips(form, options) do
    option_map = Map.new(options, fn option -> {option.name, option} end)

    Enum.map(tag_values(form), fn name ->
      option = Map.get(option_map, name)
      %{name: name, color: option && option.color}
    end)
  end

  @spec category_suggestions(term(), term(), term()) :: term()
  def category_suggestions(form, options, query) do
    selected = MapSet.new(category_values(form))
    filter_suggestions(options, query, & &1, selected)
  end

  defp filter_suggestions(options, query, labeler, selected) do
    query = normalize_query(query)

    options
    |> Enum.filter(fn option ->
      label = labeler.(option)

      not MapSet.member?(selected, label) and
        (query == "" or String.contains?(String.downcase(label), query))
    end)
    |> Enum.take(8)
  end

  @spec query_addable?(term(), term(), term(), term()) :: term()
  def query_addable?(query, selected_values, options, labeler) do
    normalized = normalize_query(query)

    normalized != "" and
      normalized not in Enum.map(selected_values, &String.downcase/1) and
      not Enum.any?(options, fn option -> String.downcase(labeler.(option)) == normalized end)
  end

  defp normalize_query(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec normalize_list_entry(term()) :: term()
  def normalize_list_entry(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec ensure_list_value(term(), term(), term()) :: term()
  def ensure_list_value(project_id, :tags, value) do
    if Enum.any?(Tags.list_tags(project_id), &(String.downcase(&1.name) == value)) do
      :ok
    else
      _ = Tags.create_tag(%{project_id: project_id, name: value})
      :ok
    end
  end

  def ensure_list_value(project_id, :categories, value) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    if value in (metadata.categories || []) do
      :ok
    else
      _ = Metadata.add_category(project_id, value)
      :ok
    end
  rescue
    error ->
      Logger.warning("swallowed list_values ensure_list_value error: #{inspect(error)}")
      :ok
  end

  @spec csv_to_list(term()) :: term()
  def csv_to_list(value) do
    value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec tag_chip_style(term()) :: term()
  def tag_chip_style(nil), do: nil

  def tag_chip_style(color) do
    normalized = normalize_color(color)

    if normalized do
      "background-color: #{normalized}; color: #{contrast_color(normalized)}; border-color: #{normalized};"
    end
  end

  # nil is handled by tag_chip_style/1 before this is reached.
  defp normalize_color("#" <> rest = color) when byte_size(rest) == 6 do
    if String.match?(rest, ~r/\A[0-9a-fA-F]{6}\z/), do: color, else: nil
  end

  defp normalize_color(_color), do: nil

  defp contrast_color("#" <> rgb) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = rgb
    {red, _} = Integer.parse(r, 16)
    {green, _} = Integer.parse(g, 16)
    {blue, _} = Integer.parse(b, 16)
    luminance = (red * 299 + green * 587 + blue * 114) / 1000
    if luminance > 150, do: "#1e1e1e", else: "#ffffff"
  end

  defp contrast_color(_color), do: "#ffffff"

  @spec ai_overlay_fields(term()) :: term()
  def ai_overlay_fields(selected), do: Enum.filter(selected, & &1.accepted)
end
