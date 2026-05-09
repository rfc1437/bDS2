defmodule BDS.CSM014LengthInLoopTest do
  use ExUnit.Case, async: true

  alias BDS.Generation.Outputs

  describe "build_paginated_archive_outputs/5 pagination correctness" do
    test "pagination values are consistent across pages" do
      posts = Enum.map(1..25, fn i -> %{id: i, slug: "post-#{i}"} end)

      plan = %{
        language: "en",
        max_posts_per_page: 10
      }

      collected = :ets.new(:pagination_collector, [:bag, :public])

      Outputs.build_paginated_archive_outputs(
        plan,
        ["en"],
        ["category", "tech"],
        posts,
        fn _page_posts, _language, pagination ->
          :ets.insert(collected, {:pagination, pagination})
          ""
        end
      )

      paginations =
        :ets.lookup(collected, :pagination)
        |> Enum.map(fn {:pagination, p} -> p end)
        |> Enum.sort_by(& &1.current_page)

      :ets.delete(collected)

      assert length(paginations) == 3

      assert Enum.all?(paginations, fn p -> p.total_items == 25 end)
      assert Enum.all?(paginations, fn p -> p.total_pages == 3 end)

      [p1, p2, p3] = paginations
      assert p1.has_prev_page == false
      assert p1.has_next_page == true
      assert p2.has_prev_page == true
      assert p2.has_next_page == true
      assert p3.has_prev_page == true
      assert p3.has_next_page == false
    end

    test "single-page result has correct pagination" do
      posts = [%{id: 1, slug: "only"}]

      plan = %{language: "en", max_posts_per_page: 10}

      collected = :ets.new(:pagination_single, [:bag, :public])

      Outputs.build_paginated_archive_outputs(
        plan,
        ["en"],
        ["tag", "elixir"],
        posts,
        fn _page_posts, _language, pagination ->
          :ets.insert(collected, {:pagination, pagination})
          ""
        end
      )

      [{:pagination, p}] = :ets.lookup(collected, :pagination)
      :ets.delete(collected)

      assert p.total_items == 1
      assert p.total_pages == 1
      assert p.has_prev_page == false
      assert p.has_next_page == false
    end
  end

  describe "linear time with large lists" do
    test "build_paginated_archive_outputs completes in linear time with 1000 posts" do
      posts = Enum.map(1..1000, fn i -> %{id: i, slug: "post-#{i}"} end)

      plan = %{
        language: "en",
        max_posts_per_page: 10
      }

      {time_us, results} =
        :timer.tc(fn ->
          Outputs.build_paginated_archive_outputs(
            plan,
            ["en"],
            ["category", "big"],
            posts,
            fn _page_posts, _language, _pagination -> "" end
          )
        end)

      assert length(results) == 100
      assert time_us < 1_000_000
    end
  end
end
