defmodule BDS.EmbeddingsTest do
  use ExUnit.Case, async: false

  defmodule FakeBackend do
    @behaviour BDS.Embeddings.Backend

    @impl true
    def model_info do
      %{model_id: "fake/multilingual-e5-small", dimensions: 384}
    end

    @impl true
    def embed(text, opts) do
      BDS.Embeddings.Backends.InApp.embed(text, opts)
    end
  end

  defmodule BatchRecordingBackend do
    @behaviour BDS.Embeddings.Backend

    @recorder :embeddings_batch_recorder

    @impl true
    def model_info do
      %{model_id: "batch/multilingual-e5-small", dimensions: 384}
    end

    @impl true
    def embed(text, opts) do
      BDS.Embeddings.Backends.InApp.embed(text, opts)
    end

    @impl true
    def embed_many(texts, opts) do
      Agent.update(@recorder, fn sizes -> [length(texts) | sizes] end)
      BDS.Embeddings.Backends.InApp.embed_many(texts, opts)
    end
  end

  defmodule CountingBackend do
    @behaviour BDS.Embeddings.Backend

    @counter :embeddings_force_counter

    @impl true
    def model_info, do: %{model_id: "counting/multilingual-e5-small", dimensions: 384}

    @impl true
    def embed(text, opts) do
      Agent.update(@counter, &(&1 + 1))
      BDS.Embeddings.Backends.InApp.embed(text, opts)
    end

    @impl true
    def embed_many(texts, opts) do
      Agent.update(@counter, &(&1 + length(texts)))
      BDS.Embeddings.Backends.InApp.embed_many(texts, opts)
    end
  end

  defmodule FailingBackend do
    @behaviour BDS.Embeddings.Backend

    @impl true
    def model_info, do: %{model_id: "failing/multilingual-e5-small", dimensions: 384}

    @impl true
    def embed(_text, _opts), do: {:error, :model_unavailable}

    @impl true
    def embed_many(_texts, _opts), do: {:error, :model_unavailable}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-embeddings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Embeddings", data_path: temp_dir})

    previous_config = Application.get_env(:bds, :embeddings)
    Application.put_env(:bds, :embeddings, backend: FakeBackend)

    on_exit(fn ->
      if previous_config == nil do
        Application.delete_env(:bds, :embeddings)
      else
        Application.put_env(:bds, :embeddings, previous_config)
      end
    end)

    %{project: project}
  end

  test "embeddings index published posts when semantic similarity is enabled and support similarity, dismissals, and tag suggestions",
       %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, alpha} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Space Travel",
               content: "space rocket launch orbit mission galaxy",
               tags: ["space", "science"],
               language: "en"
             })

    assert {:ok, beta} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Rocket Mission",
               content: "rocket launch mission orbit space station",
               tags: ["space", "mission"],
               language: "en"
             })

    assert {:ok, gamma} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Bread Baking",
               content: "flour yeast dough oven loaf kitchen",
               tags: ["food"],
               language: "en"
             })

    assert {:ok, alpha} = BDS.Posts.publish_post(alpha.id)
    assert {:ok, beta} = BDS.Posts.publish_post(beta.id)
    assert {:ok, gamma} = BDS.Posts.publish_post(gamma.id)

    assert {:ok, indexed} = BDS.Embeddings.index_unindexed(project.id)
    assert Enum.sort(indexed) == Enum.sort([alpha.id, beta.id, gamma.id])

    assert {:ok, similar} = BDS.Embeddings.find_similar(alpha.id, 2)
    assert length(similar) == 2
    assert hd(similar).post_id == beta.id
    assert hd(similar).score > List.last(similar).score

    assert {:ok, scores} = BDS.Embeddings.compute_similarities(alpha.id, [beta.id, gamma.id])
    assert scores[beta.id] > scores[gamma.id]

    assert {:ok, suggestions} = BDS.Embeddings.suggest_tags(alpha.id, "rocket orbit mission")
    assert "space" in suggestions

    assert {:ok, dismissal} = BDS.Embeddings.dismiss_duplicate_pair(alpha.id, beta.id)
    assert dismissal.project_id == project.id

    assert {:ok, alpha} = BDS.Posts.update_post(alpha.id, %{content: "kitchen flour dough loaf"})
    assert {:ok, alpha} = BDS.Posts.publish_post(alpha.id)

    assert {:ok, updated_scores} =
             BDS.Embeddings.compute_similarities(alpha.id, [beta.id, gamma.id])

    assert updated_scores[gamma.id] > updated_scores[beta.id]

    assert {:ok, :deleted} = BDS.Posts.delete_post(gamma.id)

    assert {:ok, after_delete} =
             BDS.Embeddings.compute_similarities(alpha.id, [beta.id, gamma.id])

    refute Map.has_key?(after_delete, gamma.id)
  end

  test "duplicate detection keeps exact matches and excludes lower-similarity pairs below the spec threshold",
       %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, exact_a} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Exact Match",
               content: "space rocket launch orbit mission galaxy",
               language: "en"
             })

    assert {:ok, exact_b} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Exact Match",
               content: "space rocket launch orbit mission galaxy",
               language: "en"
             })

    assert {:ok, fuzzy} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Fuzzy",
               content: "space rocket launch mission orbit space station",
               language: "en"
             })

    assert {:ok, exact_a} = BDS.Posts.publish_post(exact_a.id)
    assert {:ok, exact_b} = BDS.Posts.publish_post(exact_b.id)
    assert {:ok, fuzzy} = BDS.Posts.publish_post(fuzzy.id)

    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)
    assert {:ok, duplicates} = BDS.Embeddings.find_duplicates(project.id)

    assert [%{post_id_a: post_id_a, post_id_b: post_id_b, score: score}] = duplicates
    assert MapSet.new([post_id_a, post_id_b]) == MapSet.new([exact_a.id, exact_b.id])
    assert score >= 0.99
    assert hd(duplicates).similarity == score
    assert hd(duplicates).exact_match == true

    assert MapSet.new([hd(duplicates).title_a, hd(duplicates).title_b]) ==
             MapSet.new(["Exact Match", "Exact Match"])

    refute Enum.any?(duplicates, fn pair ->
             MapSet.new([pair.post_id_a, pair.post_id_b]) == MapSet.new([exact_a.id, fuzzy.id])
           end)
  end

  test "batch duplicate dismissal stores canonical pairs and excludes them from future searches",
       %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, exact_a} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Exact Match",
               content: "space rocket launch orbit mission galaxy",
               language: "en"
             })

    assert {:ok, exact_b} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Exact Match",
               content: "space rocket launch orbit mission galaxy",
               language: "en"
             })

    assert {:ok, exact_a} = BDS.Posts.publish_post(exact_a.id)
    assert {:ok, exact_b} = BDS.Posts.publish_post(exact_b.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    assert {:ok, duplicates} = BDS.Embeddings.find_duplicates(project.id)
    assert length(duplicates) == 1

    assert {:ok, dismissed_pairs} =
             BDS.Embeddings.dismiss_duplicate_pairs([
               {exact_b.id, exact_a.id},
               {exact_a.id, exact_b.id}
             ])

    assert length(dismissed_pairs) == 1
    assert hd(dismissed_pairs).project_id == project.id

    assert {:ok, filtered_duplicates} = BDS.Embeddings.find_duplicates(project.id)
    assert filtered_duplicates == []
  end

  test "embedding queries are gated off when semantic similarity is disabled", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Disabled",
               content: "space rocket mission"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)

    assert {:ok, []} = BDS.Embeddings.find_similar(post.id, 5)
    assert {:ok, []} = BDS.Embeddings.find_duplicates(project.id)
    assert {:ok, %{}} = BDS.Embeddings.compute_similarities(post.id, [post.id])
  end

  test "get_indexing_progress returns zero indexed and total when a project has no posts", %{
    project: project
  } do
    assert {:ok, %{indexed: 0, total: 0}} = BDS.Embeddings.get_indexing_progress(project.id)
  end

  test "get_indexing_progress returns indexed embeddings and total posts for the project", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, indexed_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Indexed",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, unindexed_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Unindexed",
               content: "flour yeast dough oven loaf kitchen",
               language: "en"
             })

    assert {:ok, indexed_post} = BDS.Posts.publish_post(indexed_post.id)

    assert {:ok, %{indexed: 2, total: 2}} = BDS.Embeddings.get_indexing_progress(project.id)

    assert unindexed_post.id != indexed_post.id
  end

  test "embeddings use the configured in-app backend module", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert BDS.Embeddings.model_id() == "fake/multilingual-e5-small"
    assert BDS.Embeddings.dimensions() == 384

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Configured Backend",
               content: "semantic runtime through the configured backend",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)

    assert {:ok, indexed} = BDS.Embeddings.index_unindexed(project.id)
    assert post.id in indexed
  end

  test "embedding indexing persists a project-local similarity snapshot", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, alpha} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Alpha",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, beta} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Beta",
               content: "rocket launch orbit mission station",
               language: "en"
             })

    assert {:ok, alpha} = BDS.Posts.publish_post(alpha.id)
    assert {:ok, beta} = BDS.Posts.publish_post(beta.id)

    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    # Persistence is debounced (5s); force it to disk to assert the files.
    :ok = BDS.Embeddings.Index.flush(project.id)

    index_path = BDS.Embeddings.index_path(project.id)
    assert File.exists?(index_path)
    assert File.exists?(index_path <> ".meta.json")
    refute String.starts_with?(index_path, BDS.Projects.project_data_dir(project))

    cache_root = Application.fetch_env!(:bds, :project_cache_root) |> Path.expand()

    assert index_path == Path.join([cache_root, "projects", project.id, "embeddings.usearch"])

    # The sidecar carries the dimension and the label→post_id mapping.
    meta = (index_path <> ".meta.json") |> File.read!() |> Jason.decode!()
    assert meta["dim"] == 384
    post_ids = Enum.map(meta["labels"], fn [_label, post_id] -> post_id end)
    assert alpha.id in post_ids
    assert beta.id in post_ids

    # The HNSW index answers nearest-neighbour queries.
    assert {:ok, [neighbor]} = BDS.Embeddings.find_similar(alpha.id, 1)
    assert neighbor.post_id == beta.id
  end

  test "embedding index uses the app-internal persisted file name", %{project: project} do
    assert BDS.Embeddings.index_path(project.id) =~ "/embeddings.usearch"
  end

  test "stored embedding vectors are packed Float32 BLOBs, not JSON text", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Blob",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    key = BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

    assert is_binary(key.vector)
    # 384 dimensions * 4 bytes per little-endian Float32 (VectorCacheInDb).
    assert byte_size(key.vector) == 384 * 4
    refute String.starts_with?(key.vector, "[")

    decoded = for <<value::float-32-little <- key.vector>>, do: value
    assert length(decoded) == 384

    # The packed vector still drives similarity queries.
    assert {:ok, scores} = BDS.Embeddings.compute_similarities(post.id, [post.id])
    assert is_map(scores)
  end

  test "rebuilding embeds posts in batches instead of one at a time", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    for index <- 1..5 do
      assert {:ok, post} =
               BDS.Posts.create_post(%{
                 project_id: project.id,
                 title: "Batch #{index}",
                 content: "space rocket orbit mission galaxy #{index}",
                 language: "en"
               })

      assert {:ok, _post} = BDS.Posts.publish_post(post.id)
    end

    # Simulate the post-migration state where the vector cache is empty, so the
    # rebuild has to (re)embed every post.
    BDS.Repo.delete_all(BDS.Embeddings.Key)

    {:ok, _recorder} = Agent.start_link(fn -> [] end, name: :embeddings_batch_recorder)

    Application.put_env(:bds, :embeddings,
      backend: BatchRecordingBackend,
      model_id: "batch/multilingual-e5-small",
      dimensions: 384,
      batch_size: 3
    )

    assert {:ok, rebuilt} = BDS.Embeddings.reindex_all(project.id)
    assert length(rebuilt) == 5

    batch_sizes = Agent.get(:embeddings_batch_recorder, & &1)

    # 5 pending posts at batch_size 3 → one batch of 3 and one of 2, never
    # one-at-a-time.
    assert Enum.sort(batch_sizes, :desc) == [3, 2]
    assert Enum.max(batch_sizes) > 1
  end

  test "reindex_all rebuilds stored embeddings for the whole project", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Reindex Target",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    original_key = BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

    assert {:ok, post} =
             BDS.Posts.update_post(post.id, %{content: "kitchen flour dough oven loaf"})

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    stale_key = BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)

    assert stale_key.content_hash != original_key.content_hash

    assert {:ok, rebuilt_ids} = BDS.Embeddings.reindex_all(project.id)
    assert post.id in rebuilt_ids

    refreshed_key = BDS.Repo.get_by!(BDS.Embeddings.Key, project_id: project.id, post_id: post.id)
    assert refreshed_key.content_hash == stale_key.content_hash

    :ok = BDS.Embeddings.Index.flush(project.id)
    assert File.exists?(BDS.Embeddings.index_path(project.id))
  end

  test "similarity queries keep working when sync_post finds the embedding already current", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, alpha} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Alpha",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, beta} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Beta",
               content: "rocket launch orbit mission station",
               language: "en"
             })

    assert {:ok, alpha} = BDS.Posts.publish_post(alpha.id)
    assert {:ok, _beta} = BDS.Posts.publish_post(beta.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    # Re-syncing with an unchanged content hash is a no-op for the index...
    assert :ok = BDS.Embeddings.sync_post(alpha.id)

    # ...and nearest-neighbour queries still resolve through the HNSW index.
    assert {:ok, [neighbor]} = BDS.Embeddings.find_similar(alpha.id, 1)
    assert neighbor.post_id == beta.id
  end

  test "find_similar rebuilds the HNSW index on demand when none is loaded", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, alpha} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Alpha",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, beta} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Beta",
               content: "rocket launch orbit mission station",
               language: "en"
             })

    assert {:ok, _alpha} = BDS.Posts.publish_post(alpha.id)
    assert {:ok, _beta} = BDS.Posts.publish_post(beta.id)
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)

    # Drop the in-memory index and remove the persisted files, then query: it
    # must self-heal by rebuilding from the DB vectors.
    :ok = BDS.Embeddings.Index.forget(project.id)
    File.rm_rf!(BDS.Projects.project_cache_dir(project.id))

    assert {:ok, similar} = BDS.Embeddings.find_similar(alpha.id, 1)
    assert [%{post_id: post_id}] = similar
    assert post_id == beta.id
  end

  test "explicit rebuild re-embeds every post even when content is unchanged", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :embeddings_force_counter)

    Application.put_env(:bds, :embeddings,
      backend: CountingBackend,
      model_id: "counting/multilingual-e5-small",
      dimensions: 384,
      batch_size: 16
    )

    for index <- 1..3 do
      assert {:ok, post} =
               BDS.Posts.create_post(%{
                 project_id: project.id,
                 title: "Force #{index}",
                 content: "space rocket orbit mission galaxy #{index}",
                 language: "en"
               })

      assert {:ok, _post} = BDS.Posts.publish_post(post.id)
    end

    # Ignore embeds triggered while creating/publishing.
    Agent.update(:embeddings_force_counter, fn _count -> 0 end)

    # index_unindexed honours the content_hash skip: nothing to re-embed.
    assert {:ok, _indexed} = BDS.Embeddings.index_unindexed(project.id)
    assert Agent.get(:embeddings_force_counter, & &1) == 0

    # An explicit rebuild re-embeds all three regardless (ReindexAll).
    assert {:ok, rebuilt} = BDS.Embeddings.reindex_all(project.id)
    assert length(rebuilt) == 3
    assert Agent.get(:embeddings_force_counter, & &1) == 3
  end

  test "embedding operations degrade gracefully when the model is unavailable", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    Application.put_env(:bds, :embeddings,
      backend: FailingBackend,
      model_id: "failing/multilingual-e5-small",
      dimensions: 384
    )

    # Saving a post must not crash even though embedding fails; it is just left
    # unindexed.
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Offline",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    assert BDS.Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: post.id) == nil

    # Explicit (re)index operations surface a clean error instead of crashing.
    assert {:error, :model_unavailable} = BDS.Embeddings.reindex_all(project.id)
    assert {:error, :model_unavailable} = BDS.Embeddings.index_unindexed(project.id)

    # Queries stay safe.
    assert {:ok, []} = BDS.Embeddings.find_similar(post.id, 5)
  end
end
