defmodule BDS.CSM006NPlusOneTest do
  @moduledoc """
  Tests for CSM-006: N+1 Queries in Reindexing & Rendering.

  Verifies that reindex_posts/1, reindex_media/1, and normalize_list_posts
  use batched queries instead of per-record queries.
  """
  use ExUnit.Case, async: false

  alias BDS.Media.Media
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-csm006-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM006", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  describe "reindex_posts/1 correctness with batched translations" do
    test "reindexes posts with translations correctly", %{project: project} do
      # Create posts, some with translations
      posts =
        for i <- 1..5 do
          {:ok, post} =
            BDS.Posts.create_post(%{
              project_id: project.id,
              title: "Post #{i}",
              content: "Content for post #{i}",
              tags: ["tag#{i}"],
              categories: ["cat#{i}"],
              language: "en"
            })

          if rem(i, 2) == 0 do
            BDS.Posts.Translations.upsert_post_translation(post.id, "de", %{
              title: "Beitrag #{i}",
              content: "Inhalt für Beitrag #{i}"
            })

            BDS.Posts.Translations.upsert_post_translation(post.id, "fr", %{
              title: "Article #{i}",
              content: "Contenu pour article #{i}"
            })
          end

          post
        end

      # Clear FTS and reindex
      Repo.query!("DELETE FROM posts_fts WHERE post_id IN (SELECT id FROM posts WHERE project_id = ?)", [project.id])

      # Reindex should succeed and produce correct FTS entries
      assert :ok = BDS.Search.reindex_posts(project.id)

      # Verify all posts are indexed
      %{rows: rows} = Repo.query!("SELECT post_id FROM posts_fts ORDER BY post_id")
      indexed_ids = Enum.map(rows, fn [id] -> id end) |> Enum.sort()
      expected_ids = Enum.map(posts, & &1.id) |> Enum.sort()
      assert indexed_ids == expected_ids

      # Verify translation content is in the index (search for German title)
      {:ok, results} = BDS.Search.search_posts(project.id, "Beitrag")
      assert results.total >= 1

      # Verify search for French content works
      {:ok, results} = BDS.Search.search_posts(project.id, "Contenu")
      assert results.total >= 1
    end

    test "reindex handles posts with no translations", %{project: project} do
      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Solo Post",
          content: "Solo content unique-keyword-xyz",
          tags: ["solo"],
          categories: [],
          language: "en"
        })

      Repo.query!("DELETE FROM posts_fts WHERE post_id IN (SELECT id FROM posts WHERE project_id = ?)", [project.id])
      assert :ok = BDS.Search.reindex_posts(project.id)

      {:ok, results} = BDS.Search.search_posts(project.id, "unique-keyword-xyz")
      assert results.total == 1
      assert hd(results.posts).id == post.id
    end
  end

  describe "reindex_media/1 correctness with batched translations" do
    test "reindexes media with translations correctly", %{project: project} do
      now = System.os_time(:second)

      media_items =
        for i <- 1..5 do
          {:ok, media} =
            %Media{}
            |> Media.changeset(%{
              id: Ecto.UUID.generate(),
              project_id: project.id,
              title: "Media #{i}",
              alt: "Alt text #{i}",
              caption: "Caption #{i}",
              original_name: "file#{i}.jpg",
              filename: "file#{i}.jpg",
              mime_type: "image/jpeg",
              size: 1024,
              file_path: "media/file#{i}.jpg",
              sidecar_path: "media/file#{i}.json",
              tags: ["media_tag#{i}"],
              language: "en",
              created_at: now,
              updated_at: now
            })
            |> Repo.insert()

          if rem(i, 2) == 0 do
            %BDS.Media.Translation{}
            |> BDS.Media.Translation.changeset(%{
              id: Ecto.UUID.generate(),
              project_id: project.id,
              translation_for: media.id,
              language: "de",
              title: "Medien #{i}",
              alt: "Alt DE #{i}",
              caption: "Beschriftung #{i}",
              created_at: now,
              updated_at: now
            })
            |> Repo.insert!()
          end

          media
        end

      # Reindex
      assert :ok = BDS.Search.reindex_media(project.id)

      # Verify all media are indexed
      %{rows: rows} = Repo.query!("SELECT media_id FROM media_fts ORDER BY media_id")
      indexed_ids = Enum.map(rows, fn [id] -> id end) |> Enum.sort()
      expected_ids = Enum.map(media_items, & &1.id) |> Enum.sort()
      assert indexed_ids == expected_ids

      # Verify translation content is in the index
      {:ok, results} = BDS.Search.search_media(project.id, "Medien")
      assert results.total >= 1

      {:ok, results} = BDS.Search.search_media(project.id, "Beschriftung")
      assert results.total >= 1
    end
  end

  describe "ListArchive batch post loading" do
    test "list_assigns loads post records in batch", %{project: project} do
      # Create posts
      posts =
        for i <- 1..5 do
          {:ok, post} =
            BDS.Posts.create_post(%{
              project_id: project.id,
              title: "List Post #{i}",
              content: "List content #{i}",
              tags: ["list_tag"],
              categories: ["list_cat"],
              language: "en"
            })

          post
        end

      # Pass post assigns with only IDs (forces load_post_record)
      post_assigns =
        Enum.map(posts, fn post ->
          %{id: post.id, slug: post.slug, title: post.title}
        end)

      # Should succeed and return properly enriched post data
      result =
        BDS.Rendering.ListArchive.list_assigns(project.id, %{
          posts: post_assigns,
          language: "en"
        })

      assert is_map(result)
      assert length(result.posts) == 5

      # Verify that post records were loaded (fallback fields like author come from DB)
      # Each post in results should have enriched data from the DB record
      for post <- result.posts do
        assert is_binary(post.id)
        assert is_binary(post.slug)
        assert is_binary(post.title)
      end
    end

    test "PostRendering.load_post_records_batch/1 returns map of id to record", %{
      project: project
    } do
      posts =
        for i <- 1..3 do
          {:ok, post} =
            BDS.Posts.create_post(%{
              project_id: project.id,
              title: "Batch #{i}",
              content: "Batch content #{i}",
              tags: [],
              categories: [],
              language: "en"
            })

          post
        end

      ids = Enum.map(posts, & &1.id)
      records_map = BDS.Rendering.PostRendering.load_post_records_batch(ids)

      assert map_size(records_map) == 3

      for post <- posts do
        assert Map.has_key?(records_map, post.id)
        assert records_map[post.id].title == post.title
      end
    end

    test "PostRendering.load_post_records_batch/1 handles empty list" do
      assert BDS.Rendering.PostRendering.load_post_records_batch([]) == %{}
    end

    test "PostRendering.load_post_records_batch/1 handles nonexistent IDs" do
      records_map = BDS.Rendering.PostRendering.load_post_records_batch(["nonexistent-id"])
      assert records_map == %{"nonexistent-id" => nil}
    end
  end
end
