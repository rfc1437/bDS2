defmodule BDS.CSM005SQLFilteringTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Media
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags
  alias BDS.UI.Dashboard
  alias BDS.UI.Sidebar

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm005-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM005", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  # ---------------------------------------------------------------------------
  # Posts.dashboard_stats uses GROUP BY instead of loading all rows
  # ---------------------------------------------------------------------------

  describe "Posts.dashboard_stats/1" do
    test "returns correct counts grouped by status", %{project: project} do
      for _ <- 1..3, do: create_post(project.id, status: :draft)
      for _ <- 1..2, do: create_post(project.id, status: :published)
      create_post(project.id, status: :archived)

      stats = Posts.dashboard_stats(project.id)

      assert stats.total_posts == 6
      assert stats.draft_count == 3
      assert stats.published_count == 2
      assert stats.archived_count == 1
    end

    test "returns zeroes when no posts exist", %{project: project} do
      stats = Posts.dashboard_stats(project.id)

      assert stats == %{
               total_posts: 0,
               draft_count: 0,
               published_count: 0,
               archived_count: 0
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Dashboard.snapshot uses SQL aggregates
  # ---------------------------------------------------------------------------

  describe "Dashboard.snapshot/1" do
    test "computes post_stats via SQL aggregate", %{project: project} do
      for _ <- 1..2, do: create_post(project.id, status: :draft)
      create_post(project.id, status: :published)

      snapshot = Dashboard.snapshot(project.id)

      assert snapshot.post_stats.total_posts == 3
      assert snapshot.post_stats.draft_count == 2
      assert snapshot.post_stats.published_count == 1
      assert snapshot.post_stats.archived_count == 0
    end

    test "computes media_stats via SQL aggregate", %{project: project, temp_dir: temp_dir} do
      create_media(project.id, temp_dir, "image.png", "image/png", 1024)
      create_media(project.id, temp_dir, "video.mp4", "video/mp4", 2048)
      create_media(project.id, temp_dir, "photo.jpg", "image/jpeg", 512)

      snapshot = Dashboard.snapshot(project.id)

      assert snapshot.media_stats.media_count == 3
      assert snapshot.media_stats.image_count == 2
      assert snapshot.media_stats.total_bytes == 1024 + 2048 + 512
    end

    test "computes tag_cloud_items via SQL json_each", %{project: project} do
      create_post(project.id, tags: ["elixir", "phoenix"])
      create_post(project.id, tags: ["elixir", "ecto"])
      create_post(project.id, tags: ["rust"])

      snapshot = Dashboard.snapshot(project.id)

      cloud = Map.new(snapshot.tag_cloud_items, fn item -> {item.tag, item.count} end)
      assert cloud["elixir"] == 2
      assert cloud["phoenix"] == 1
      assert cloud["ecto"] == 1
      assert cloud["rust"] == 1
    end

    test "computes category_counts via SQL json_each", %{project: project} do
      create_post(project.id, categories: ["tutorial", "beginner"])
      create_post(project.id, categories: ["tutorial", "advanced"])

      snapshot = Dashboard.snapshot(project.id)

      counts = Map.new(snapshot.category_counts, fn item -> {item.category, item.count} end)
      assert counts["tutorial"] == 2
      assert counts["beginner"] == 1
      assert counts["advanced"] == 1
    end

    test "recent_posts uses SQL LIMIT", %{project: project} do
      for i <- 1..10 do
        {:ok, post} = create_post(project.id, title: "Post #{i}")

        Repo.update_all(
          from(p in Post, where: p.id == ^post.id),
          set: [updated_at: i * 1000]
        )
      end

      snapshot = Dashboard.snapshot(project.id)

      assert length(snapshot.recent_posts) == 5
      assert hd(snapshot.recent_posts).title == "Post 10"
    end

    test "returns empty_snapshot for nil project" do
      snapshot = Dashboard.snapshot(nil)
      assert snapshot.post_stats.total_posts == 0
      assert snapshot.media_stats.media_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Tags module uses SQL json_each for tag queries
  # ---------------------------------------------------------------------------

  describe "Tags SQL filtering" do
    test "delete_tag only affects posts with that tag via SQL", %{project: project} do
      {:ok, tag} = Tags.create_tag(%{project_id: project.id, name: "Target"})
      {:ok, tagged_post} = create_post(project.id, tags: ["Target", "Other"])
      {:ok, untagged_post} = create_post(project.id, tags: ["Other"])

      {:ok, :deleted} = Tags.delete_tag(tag.id)

      reloaded_tagged = Repo.get!(Post, tagged_post.id)
      reloaded_untagged = Repo.get!(Post, untagged_post.id)

      assert reloaded_tagged.tags == ["Other"]
      assert reloaded_untagged.tags == ["Other"]
    end

    test "rename_tag only touches posts with the old tag via SQL", %{project: project} do
      {:ok, tag} = Tags.create_tag(%{project_id: project.id, name: "OldName"})
      {:ok, tagged_post} = create_post(project.id, tags: ["OldName", "Keep"])
      {:ok, other_post} = create_post(project.id, tags: ["Keep"])

      {:ok, _renamed} = Tags.rename_tag(tag.id, "NewName")

      assert Repo.get!(Post, tagged_post.id).tags == ["NewName", "Keep"]
      assert Repo.get!(Post, other_post.id).tags == ["Keep"]
    end

    test "merge_tags finds posts with any source tag via SQL", %{project: project} do
      {:ok, src_a} = Tags.create_tag(%{project_id: project.id, name: "A"})
      {:ok, src_b} = Tags.create_tag(%{project_id: project.id, name: "B"})
      {:ok, target} = Tags.create_tag(%{project_id: project.id, name: "C"})

      {:ok, post_a} = create_post(project.id, tags: ["A"])
      {:ok, post_b} = create_post(project.id, tags: ["B"])
      {:ok, post_none} = create_post(project.id, tags: ["D"])

      {:ok, :merged} = Tags.merge_tags([src_a.id, src_b.id], target.id)

      assert "C" in Repo.get!(Post, post_a.id).tags
      assert "C" in Repo.get!(Post, post_b.id).tags
      refute "C" in Repo.get!(Post, post_none.id).tags
    end
  end

  # ---------------------------------------------------------------------------
  # Sidebar uses SQL-level filtering
  # ---------------------------------------------------------------------------

  describe "Sidebar SQL-level filtering" do
    test "posts_view separates pages from non-page posts via SQL", %{project: project} do
      create_post(project.id, title: "Blog Post", categories: ["tutorial"])
      create_post(project.id, title: "About Page", categories: ["page"])

      posts_view = Sidebar.view(project.id, "posts")
      pages_view = Sidebar.view(project.id, "pages")

      post_titles = all_item_titles(posts_view)
      page_titles = all_item_titles(pages_view)

      assert "Blog Post" in post_titles
      refute "About Page" in post_titles
      assert "About Page" in page_titles
      refute "Blog Post" in page_titles
    end

    test "sidebar applies tag filter at SQL level", %{project: project} do
      create_post(project.id, title: "Elixir Post", tags: ["elixir"])
      create_post(project.id, title: "Rust Post", tags: ["rust"])
      create_post(project.id, title: "Both", tags: ["elixir", "rust"])

      view = Sidebar.view(project.id, "posts", %{tags: ["elixir"]})

      titles = all_item_titles(view)
      assert "Elixir Post" in titles
      assert "Both" in titles
      refute "Rust Post" in titles
      assert view.filters.total_count == 2
    end

    test "sidebar applies search filter at SQL level", %{project: project} do
      create_post(project.id, title: "Alpha Release")
      create_post(project.id, title: "Beta Release")
      create_post(project.id, title: "Gamma Notes")

      view = Sidebar.view(project.id, "posts", %{search: "release"})

      titles = all_item_titles(view)
      assert "Alpha Release" in titles
      assert "Beta Release" in titles
      refute "Gamma Notes" in titles
      assert view.filters.total_count == 2
    end

    test "sidebar applies year/month filter at SQL level", %{project: project} do
      {:ok, post_jan} = create_post(project.id, title: "January Post")
      {:ok, post_feb} = create_post(project.id, title: "February Post")

      jan_ts = DateTime.to_unix(~U[2025-01-15 12:00:00Z], :millisecond)
      feb_ts = DateTime.to_unix(~U[2025-02-15 12:00:00Z], :millisecond)

      Repo.update_all(from(p in Post, where: p.id == ^post_jan.id),
        set: [updated_at: jan_ts, published_at: nil]
      )

      Repo.update_all(from(p in Post, where: p.id == ^post_feb.id),
        set: [updated_at: feb_ts, published_at: nil]
      )

      view = Sidebar.view(project.id, "posts", %{year: 2025, month: 1})

      titles = all_item_titles(view)
      assert "January Post" in titles
      refute "February Post" in titles
    end

    test "sidebar computes available_tags from SQL", %{project: project} do
      create_post(project.id, tags: ["elixir", "phoenix"])
      create_post(project.id, tags: ["elixir", "ecto"])

      view = Sidebar.view(project.id, "posts")

      assert "elixir" in view.filters.available_tags
      assert "phoenix" in view.filters.available_tags
      assert "ecto" in view.filters.available_tags
    end

    test "sidebar computes available_categories excluding 'page' from SQL", %{project: project} do
      create_post(project.id, categories: ["page", "tutorial"])
      create_post(project.id, categories: ["page", "reference"])

      view = Sidebar.view(project.id, "pages")

      refute "page" in view.filters.available_categories
      assert "tutorial" in view.filters.available_categories
      assert "reference" in view.filters.available_categories
    end

    test "sidebar computes year_month_counts from SQL", %{project: project} do
      {:ok, p1} = create_post(project.id, title: "P1")
      {:ok, p2} = create_post(project.id, title: "P2")
      {:ok, p3} = create_post(project.id, title: "P3")

      ts_2025_03 = DateTime.to_unix(~U[2025-03-15 12:00:00Z], :millisecond)
      ts_2025_04 = DateTime.to_unix(~U[2025-04-15 12:00:00Z], :millisecond)

      Repo.update_all(from(p in Post, where: p.id == ^p1.id), set: [updated_at: ts_2025_03])
      Repo.update_all(from(p in Post, where: p.id == ^p2.id), set: [updated_at: ts_2025_03])
      Repo.update_all(from(p in Post, where: p.id == ^p3.id), set: [updated_at: ts_2025_04])

      view = Sidebar.view(project.id, "posts")

      year_months = view.filters.year_month_counts
      mar = Enum.find(year_months, &(&1.year == 2025 and &1.month == 3))
      apr = Enum.find(year_months, &(&1.year == 2025 and &1.month == 4))

      assert mar.count == 2
      assert apr.count == 1
    end

    test "media_view applies tag filter at SQL level", %{
      project: project,
      temp_dir: temp_dir
    } do
      {:ok, _m1} = create_media(project.id, temp_dir, "elixir.png", "image/png", 100, ["elixir"])
      {:ok, _m2} = create_media(project.id, temp_dir, "rust.png", "image/png", 100, ["rust"])

      view = Sidebar.view(project.id, "media", %{tags: ["elixir"]})

      titles = Enum.map(view.items, & &1.title)
      assert "elixir.png" in titles
      refute "rust.png" in titles
      assert view.filters.total_count == 1
    end

    test "group_posts uses Enum.group_by (no O(n²) append)", %{project: project} do
      create_post(project.id, title: "D1", status: :draft)
      create_post(project.id, title: "P1", status: :published)
      create_post(project.id, title: "A1", status: :archived)
      create_post(project.id, title: "D2", status: :draft)

      view = Sidebar.view(project.id, "posts")

      draft_section = Enum.find(view.sections, &(&1.id == "draft"))
      published_section = Enum.find(view.sections, &(&1.id == "published"))
      archived_section = Enum.find(view.sections, &(&1.id == "archived"))

      assert draft_section.count == 2
      assert published_section.count == 1
      assert archived_section.count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_post(project_id, opts) do
    title = Keyword.get(opts, :title, "Post #{System.unique_integer([:positive])}")
    status = Keyword.get(opts, :status, :draft)
    tags = Keyword.get(opts, :tags, [])
    categories = Keyword.get(opts, :categories, [])

    {:ok, post} =
      Posts.create_post(%{
        project_id: project_id,
        title: title,
        content: "Body",
        tags: tags,
        categories: categories
      })

    if status != :draft do
      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [status: status])
      {:ok, Repo.get!(Post, post.id)}
    else
      {:ok, post}
    end
  end

  defp create_media(project_id, temp_dir, filename, mime_type, size, tags \\ []) do
    source_path = Path.join(temp_dir, "src-#{filename}")
    File.write!(source_path, String.duplicate("x", size))

    {:ok, media} =
      Media.import_media(%{
        project_id: project_id,
        source_path: source_path,
        title: filename,
        tags: tags
      })

    Repo.update_all(
      from(m in BDS.Media.Media, where: m.id == ^media.id),
      set: [mime_type: mime_type, size: size]
    )

    {:ok, Repo.get!(BDS.Media.Media, media.id)}
  end

  defp all_item_titles(view) do
    (view[:sections] || [])
    |> Enum.flat_map(& &1.items)
    |> Enum.map(& &1.title)
  end
end
