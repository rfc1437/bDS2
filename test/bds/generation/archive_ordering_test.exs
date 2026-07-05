defmodule BDS.Generation.ArchiveOrderingTest do
  @moduledoc """
  Category, tag and date archive listings must render newest first. The
  generation post index is built by prepending, so this guards against the
  regression where grouped archive lists came out in an unstable/oldest-first
  order.
  """
  use ExUnit.Case, async: true

  alias BDS.Generation.Data

  defp post(slug, created_at, categories, tags) do
    %{
      id: slug,
      slug: slug,
      created_at: created_at,
      published_at: created_at,
      categories: categories,
      tags: tags
    }
  end

  test "categories, tags and dates are ordered newest first regardless of input order" do
    older = post("older", 1_700_000_000_000, ["article"], ["elixir"])
    newest = post("newest", 1_700_000_200_000, ["article"], ["elixir"])
    middle = post("middle", 1_700_000_100_000, ["article"], ["elixir"])

    # Deliberately unordered input.
    index = Data.build_generation_post_index([older, newest, middle])

    expected = ["newest", "middle", "older"]

    assert Enum.map(index.posts_by_category["article"], & &1.slug) == expected
    assert Enum.map(index.posts_by_tag["elixir"], & &1.slug) == expected

    {year, _month, _day} = BDS.Generation.Paths.local_date_parts!(newest.created_at)
    assert Enum.map(index.posts_by_year[year], & &1.slug) == expected
  end
end
