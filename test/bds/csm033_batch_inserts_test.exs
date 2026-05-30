defmodule BDS.CSM033BatchInsertsTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  describe "source-level: embeddings.ex uses batch inserts instead of Enum.each + individual writes" do
    setup do
      source = File.read!("lib/bds/embeddings.ex")
      %{source: source}
    end

    test "no Enum.each calling sync_post_if_enabled in bulk paths", %{source: source} do
      refute source =~ "Enum.each(posts, &sync_post_if_enabled",
             "bulk paths should not use Enum.each with sync_post_if_enabled"

      refute source =~ ~r/Enum\.each\(fn \{post, index\} ->\n\s+sync_post_if_enabled/,
             "bulk paths should not use Enum.each with sync_post_if_enabled"
    end

    test "bulk functions use batch_upsert_keys", %{source: source} do
      assert source =~ "batch_upsert_keys(rows)",
             "expected batch_upsert_keys to be called with collected rows"
    end

    test "bulk functions preload keys before the loop", %{source: source} do
      assert source =~ "preload_keys_by_post_id(project_id)",
             "expected keys to be preloaded in a single query"
    end

    test "batch_upsert_keys uses multi-row INSERT with ON CONFLICT upsert", %{source: source} do
      assert source =~ "INSERT INTO embedding_keys",
             "expected raw SQL batch INSERT for embedding keys"

      assert source =~ "ON CONFLICT(label) DO UPDATE",
             "expected ON CONFLICT upsert clause"
    end

    test "build_key_rows computes rows for batched upsert instead of individual Repo.insert_or_update",
         %{source: source} do
      assert source =~ "build_key_rows(posts, existing_keys",
             "expected build_key_rows helper for batched row computation"

      assert source =~ "embed_many(",
             "expected batched embedding via embed_many"
    end
  end

  describe "source-level: search.ex already uses batch inserts" do
    test "batch_insert_post_index uses multi-row VALUES" do
      source = File.read!("lib/bds/search.ex")
      assert source =~ "batch_insert_post_index"
      assert source =~ ~r/INSERT INTO posts_fts.*VALUES.*\#\{placeholders\}/s
    end

    test "batch_insert_media_index uses multi-row VALUES" do
      source = File.read!("lib/bds/search.ex")
      assert source =~ "batch_insert_media_index"
      assert source =~ ~r/INSERT INTO media_fts.*VALUES.*\#\{placeholders\}/s
    end
  end

  describe "functional: batch operations produce correct results" do
    defmodule FakeBackend do
      @behaviour BDS.Embeddings.Backend

      @impl true
      def model_info, do: %{model_id: "fake/test-model", dimensions: 384}

      @impl true
      def embed(text, opts), do: BDS.Embeddings.Backends.InApp.embed(text, opts)
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

      temp_dir =
        Path.join(System.tmp_dir!(), "bds-csm033-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} = BDS.Projects.create_project(%{name: "CSM033", data_path: temp_dir})

      previous_config = Application.get_env(:bds, :embeddings)
      Application.put_env(:bds, :embeddings, backend: FakeBackend)

      on_exit(fn ->
        if previous_config == nil do
          Application.delete_env(:bds, :embeddings)
        else
          Application.put_env(:bds, :embeddings, previous_config)
        end
      end)

      assert {:ok, _metadata} =
               BDS.Metadata.update_project_metadata(project.id, %{
                 semantic_similarity_enabled: true
               })

      %{project: project}
    end

    test "index_unindexed batch-inserts keys for multiple posts", %{project: project} do
      posts =
        for i <- 1..5 do
          {:ok, post} =
            BDS.Posts.create_post(%{
              project_id: project.id,
              title: "Post #{i}",
              content: "content for post number #{i} with unique words #{:rand.uniform(10000)}",
              language: "en"
            })

          post
        end

      {:ok, indexed} = BDS.Embeddings.index_unindexed(project.id)
      assert length(indexed) == 5
      assert Enum.all?(posts, fn post -> post.id in indexed end)

      keys =
        BDS.Repo.all(from(k in BDS.Embeddings.Key, where: k.project_id == ^project.id))

      assert length(keys) == 5
      labels = Enum.map(keys, & &1.label) |> Enum.sort()
      assert labels == Enum.to_list(1..5)
    end

    test "rebuild_project updates stale keys via batch upsert", %{project: project} do
      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Rebuild Target",
          content: "original content for rebuild test",
          language: "en"
        })

      {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

      original_key =
        BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

      {:ok, _post} =
        BDS.Posts.update_post(post.id, %{content: "completely different content now"})

      {:ok, rebuilt_ids} = BDS.Embeddings.rebuild_project(project.id)
      assert post.id in rebuilt_ids

      updated_key =
        BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

      assert updated_key.label == original_key.label
      assert updated_key.content_hash != original_key.content_hash
    end

    test "repair_posts batch-upserts for specified posts only", %{project: project} do
      {:ok, post_a} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Repair A",
          content: "content A",
          language: "en"
        })

      {:ok, _post_b} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Repair B",
          content: "content B",
          language: "en"
        })

      {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)
      {:ok, repaired} = BDS.Embeddings.repair_posts(project.id, [post_a.id])
      assert repaired == [post_a.id]

      keys =
        BDS.Repo.all(from(k in BDS.Embeddings.Key, where: k.project_id == ^project.id))

      assert length(keys) == 2
    end

    test "index_unindexed skips posts with matching content hash", %{project: project} do
      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Skip Test",
          content: "unchanged content for skip test",
          language: "en"
        })

      {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

      key_before =
        BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

      {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

      key_after =
        BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

      assert key_before.label == key_after.label
      assert key_before.content_hash == key_after.content_hash
      assert key_before.vector == key_after.vector
    end
  end
end
