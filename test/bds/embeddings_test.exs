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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-embeddings-#{System.unique_integer([:positive])}")
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

  test "embeddings index published posts when semantic similarity is enabled and support similarity, duplicates, dismissals, and tag suggestions",
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

    assert {:ok, duplicates} = BDS.Embeddings.find_duplicates(project.id)
    assert Enum.any?(duplicates, fn pair ->
             MapSet.new([pair.post_id_a, pair.post_id_b]) == MapSet.new([alpha.id, beta.id])
           end)

    assert {:ok, dismissal} = BDS.Embeddings.dismiss_duplicate_pair(alpha.id, beta.id)
    assert dismissal.project_id == project.id

    assert {:ok, filtered_duplicates} = BDS.Embeddings.find_duplicates(project.id)

    refute Enum.any?(filtered_duplicates, fn pair ->
             MapSet.new([pair.post_id_a, pair.post_id_b]) == MapSet.new([alpha.id, beta.id])
           end)

    assert {:ok, alpha} = BDS.Posts.update_post(alpha.id, %{content: "kitchen flour dough loaf"})
    assert {:ok, alpha} = BDS.Posts.publish_post(alpha.id)

    assert {:ok, updated_scores} = BDS.Embeddings.compute_similarities(alpha.id, [beta.id, gamma.id])
    assert updated_scores[gamma.id] > updated_scores[beta.id]

    assert {:ok, :deleted} = BDS.Posts.delete_post(gamma.id)

    assert {:ok, after_delete} = BDS.Embeddings.compute_similarities(alpha.id, [beta.id, gamma.id])
    refute Map.has_key?(after_delete, gamma.id)
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
end
