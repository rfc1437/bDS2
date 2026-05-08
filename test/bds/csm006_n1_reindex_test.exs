defmodule BDS.CSM006N1ReindexTest do
  use ExUnit.Case, async: false

  alias BDS.Posts
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Repo
  alias BDS.Search

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm006-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM006", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  describe "Search.reindex_posts/2" do
    test "uses batch inserts — query count does not scale with post count", %{project: project} do
      _post_ids = create_posts_with_translations(project.id, 100)

      query_count = count_queries(fn -> Search.reindex_posts(project.id) end)

      # 1 DELETE + 1 SELECT posts + 1 SELECT translations + 1 batch INSERT = 4
      # (may be a few more for chunking, but must be << 100)
      assert query_count > 0, "Telemetry counting returned 0 — check event name"
      assert query_count < 10, "Expected <10 queries for 100 posts, got #{query_count}"
    end

    test "correctly indexes posts and their translations", %{project: project} do
      {:ok, post1} =
        Posts.create_post(%{
          project_id: project.id,
          title: "Test Post",
          slug: "test-post",
          excerpt: "A test post",
          status: :published
        })

      BDS.Posts.Translations.upsert_post_translation(post1.id, "de", %{
        title: "Testbeitrag",
        excerpt: "Ein Testbeitrag"
      })

      Search.reindex_posts(project.id)

      result =
        Repo.query!(
          "SELECT COUNT(*) as count FROM posts_fts WHERE post_id = ?",
          [post1.id]
        )

      assert result.rows == [[1]]
    end
  end

  describe "Search.reindex_media/2" do
    test "uses batch inserts — query count does not scale with media count", %{project: project} do
      _media_ids = create_media_with_translations(project.id, 100)

      query_count = count_queries(fn -> Search.reindex_media(project.id) end)

      assert query_count > 0, "Telemetry counting returned 0 — check event name"
      assert query_count < 10, "Expected <10 queries for 100 media items, got #{query_count}"
    end

    test "correctly indexes media and their translations", %{project: project} do
      now = System.os_time(:second)

      {:ok, media} =
        %MediaRecord{}
        |> MediaRecord.changeset(%{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          title: "Test Image",
          original_name: "test.jpg",
          filename: "test.jpg",
          mime_type: "image/jpeg",
          size: 1024,
          file_path: "uploads/test.jpg",
          sidecar_path: "uploads/test.json",
          language: "en",
          created_at: now,
          updated_at: now
        })
        |> Repo.insert()

      %MediaTranslation{}
      |> MediaTranslation.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        translation_for: media.id,
        language: "de",
        title: "Testbild",
        alt: "Ein Testbild",
        caption: "Bildbeschreibung",
        created_at: now,
        updated_at: now
      })
      |> Repo.insert!()

      Search.reindex_media(project.id)

      result =
        Repo.query!(
          "SELECT COUNT(*) as count FROM media_fts WHERE media_id = ?",
          [media.id]
        )

      assert result.rows == [[1]]
    end
  end

  defp create_posts_with_translations(project_id, count) do
    Enum.map(1..count, fn i ->
      {:ok, post} =
        Posts.create_post(%{
          project_id: project_id,
          title: "Post #{i}",
          slug: "post-#{i}",
          excerpt: "Excerpt #{i}",
          status: :published
        })

      BDS.Posts.Translations.upsert_post_translation(post.id, "de", %{
        title: "Beitrag #{i}",
        excerpt: "Auszug #{i}"
      })

      post.id
    end)
  end

  defp create_media_with_translations(project_id, count) do
    now = System.os_time(:second)

    Enum.map(1..count, fn i ->
      {:ok, media} =
        %MediaRecord{}
        |> MediaRecord.changeset(%{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          title: "Media #{i}",
          original_name: "file#{i}.jpg",
          filename: "file#{i}.jpg",
          mime_type: "image/jpeg",
          size: 1024 + i,
          file_path: "uploads/file#{i}.jpg",
          sidecar_path: "uploads/file#{i}.json",
          language: "en",
          created_at: now,
          updated_at: now
        })
        |> Repo.insert()

      %MediaTranslation{}
      |> MediaTranslation.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        translation_for: media.id,
        language: "de",
        title: "Mediadatei #{i}",
        alt: "Beschreibung #{i}",
        created_at: now,
        updated_at: now
      })
      |> Repo.insert!()

      media.id
    end)
  end

  defp count_queries(func) do
    test_pid = self()
    ref = make_ref()

    handler_id = "csm006-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:bds, :repo, :query],
      fn _event, _measurements, _metadata, _ ->
        send(test_pid, {:query_executed, ref})
      end,
      nil
    )

    func.()

    :telemetry.detach(handler_id)

    count_messages(ref, 0)
  end

  defp count_messages(ref, acc) do
    receive do
      {:query_executed, ^ref} -> count_messages(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
