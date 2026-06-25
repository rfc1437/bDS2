defmodule BDS.AI.ChatToolQueryHelpers do
  @moduledoc false

  alias BDS.Search

  def normalize_limit(value) when is_integer(value) and value > 0 and value <= 50, do: value
  def normalize_limit(_value), do: 10

  def normalize_offset(value) when is_integer(value) and value >= 0, do: value
  def normalize_offset(_value), do: 0

  def search_filters(arguments) do
    %{}
    |> BDS.MapUtils.maybe_put(:category, BDS.MapUtils.blank_to_nil(arguments["category"]))
    |> BDS.MapUtils.maybe_put(:tags, BDS.MapUtils.blank_to_nil(arguments["tags"]))
    |> BDS.MapUtils.maybe_put(:language, BDS.MapUtils.blank_to_nil(arguments["language"]))
    |> BDS.MapUtils.maybe_put(
      :missing_translation_language,
      BDS.MapUtils.blank_to_nil(arguments["missingTranslationLanguage"])
    )
    |> BDS.MapUtils.maybe_put(:year, arguments["year"])
    |> BDS.MapUtils.maybe_put(:month, arguments["month"])
    |> BDS.MapUtils.maybe_put(:status, BDS.BoundedAtoms.post_status(arguments["status"]))
    |> Map.put(:offset, normalize_offset(arguments["offset"]))
    |> Map.put(:limit, normalize_limit(arguments["limit"]))
  end

  def search_all_counted_posts(project_id, arguments) do
    filters = search_filters(arguments) |> Map.put(:offset, 0) |> Map.put(:limit, 1)
    {:ok, %{total: total}} = Search.search_posts(project_id, "", filters)

    filters = Map.put(filters, :limit, max(total, 1))
    {:ok, result} = Search.search_posts(project_id, "", filters)

    result
  end

  def search_result(project_id, query, filters, mapper) do
    {:ok, result} = Search.search_posts(project_id, query, filters)

    %{
      posts: Enum.map(result.posts, mapper),
      total: result.total,
      offset: result.offset,
      limit: result.limit,
      has_more: result.offset + result.limit < result.total
    }
  end
end
