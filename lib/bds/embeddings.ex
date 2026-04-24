defmodule BDS.Embeddings do
  @moduledoc false

  import Ecto.Query

  alias BDS.Embeddings.DismissedDuplicatePair
  alias BDS.Embeddings.Key
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  @duplicate_threshold 0.5

  def model_id, do: configured_backend().model_info().model_id
  def dimensions, do: configured_backend().model_info().dimensions

  def sync_post(%Post{} = post) do
    if enabled_for_project?(post.project_id) do
      body = resolve_post_body(post)
      raw_text = compose_embedding_source(post.title, body)
      content_hash = hash_text(raw_text)

      case Repo.get_by(Key, post_id: post.id, project_id: post.project_id) do
        %Key{content_hash: ^content_hash} ->
          :ok

        existing_key ->
          label = existing_key_label(existing_key) || next_label()
          {:ok, vector} = embed_text(raw_text, post.language)

          (existing_key || %Key{})
          |> Key.changeset(%{
            label: label,
            post_id: post.id,
            project_id: post.project_id,
            content_hash: content_hash,
            vector: Jason.encode!(vector)
          })
          |> Repo.insert_or_update()

          :ok
      end
    else
      :ok
    end
  end

  def sync_post(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil -> :ok
      post -> sync_post(post)
    end
  end

  def remove_post(post_id) when is_binary(post_id) do
    Repo.delete_all(from key in Key, where: key.post_id == ^post_id)
    :ok
  end

  def index_unindexed(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      posts =
        Repo.all(from post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at, asc: post.slug])

      Enum.each(posts, fn post ->
          body = resolve_post_body(post)
          content_hash = hash_text(compose_embedding_source(post.title, body))

          case Repo.get_by(Key, post_id: post.id, project_id: project_id) do
            %Key{content_hash: ^content_hash} -> :ok
            _other ->
              :ok = sync_post(%{post | content: if(post.content in [nil, ""], do: body, else: post.content)})
          end
        end)

      indexed = Repo.all(from key in Key, where: key.project_id == ^project_id, select: key.post_id)

      {:ok, indexed}
    else
      {:ok, []}
    end
  end

  def find_similar(post_id, limit \\ 5) when is_binary(post_id) and is_integer(limit) do
    case source_post_and_vector(post_id) do
      {:disabled, _project_id} -> {:ok, []}
      {:error, :not_found} -> {:ok, []}
      {:ok, post, source_vector} ->
        similar =
          Repo.all(from key in Key, where: key.project_id == ^post.project_id and key.post_id != ^post.id)
          |> Enum.map(fn key -> %{post_id: key.post_id, score: cosine_similarity(source_vector, decode_vector(key.vector))} end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(max(limit, 0))

        {:ok, similar}
    end
  end

  def compute_similarities(source_post_id, target_post_ids)
      when is_binary(source_post_id) and is_list(target_post_ids) do
    case source_post_and_vector(source_post_id) do
      {:disabled, _project_id} -> {:ok, %{}}
      {:error, :not_found} -> {:ok, %{}}
      {:ok, post, source_vector} ->
        target_ids = Enum.uniq(target_post_ids)

        scores =
          Repo.all(from key in Key, where: key.project_id == ^post.project_id and key.post_id in ^target_ids)
          |> Enum.reduce(%{}, fn key, acc ->
            if key.post_id == source_post_id do
              acc
            else
              Map.put(acc, key.post_id, cosine_similarity(source_vector, decode_vector(key.vector)))
            end
          end)

        {:ok, scores}
    end
  end

  def suggest_tags(post_id, _input_text) when is_binary(post_id) do
    with {:ok, _post} <- fetch_post(post_id),
         {:ok, similar} <- find_similar(post_id, 10) do
      suggestions =
        Repo.all(from other in Post, where: other.id in ^Enum.map(similar, & &1.post_id))
        |> Map.new(&{&1.id, &1})
        |> then(fn posts_by_id ->
          Enum.reduce(similar, %{}, fn %{post_id: similar_post_id, score: score}, acc ->
            case Map.get(posts_by_id, similar_post_id) do
              nil -> acc
              similar_post ->
                Enum.reduce(similar_post.tags || [], acc, fn tag, tag_acc ->
                  Map.update(tag_acc, tag, score, &(&1 + score))
                end)
            end
          end)
        end)
        |> Enum.sort_by(fn {_tag, score} -> score end, :desc)
        |> Enum.take(5)
        |> Enum.map(fn {tag, _score} -> tag end)

      {:ok, suggestions}
    else
      {:error, :not_found} -> {:ok, []}
      {:disabled, _project_id} -> {:ok, []}
    end
  end

  def find_duplicates(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      dismissed = dismissed_pair_keys(project_id)
      keys = Repo.all(from key in Key, where: key.project_id == ^project_id, order_by: [asc: key.post_id])

      duplicates =
        for left <- keys,
            right <- keys,
            left.post_id < right.post_id,
            pair_key(left.post_id, right.post_id) not in dismissed,
            similarity = cosine_similarity(decode_vector(left.vector), decode_vector(right.vector)),
            similarity >= @duplicate_threshold do
          %{
            post_id_a: left.post_id,
            post_id_b: right.post_id,
            score: similarity
          }
        end
        |> Enum.sort_by(& &1.score, :desc)

      {:ok, duplicates}
    else
      {:ok, []}
    end
  end

  def dismiss_duplicate_pair(post_id_a, post_id_b)
      when is_binary(post_id_a) and is_binary(post_id_b) do
    with {:ok, post_a} <- fetch_post(post_id_a),
         {:ok, post_b} <- fetch_post(post_id_b),
         true <- post_a.project_id == post_b.project_id do
      {sorted_a, sorted_b} = sort_pair(post_id_a, post_id_b)

      pair =
        Repo.get_by(DismissedDuplicatePair,
          project_id: post_a.project_id,
          post_id_a: sorted_a,
          post_id_b: sorted_b
        ) || %DismissedDuplicatePair{}

      saved_pair =
        pair
        |> DismissedDuplicatePair.changeset(%{
          id: pair.id || Ecto.UUID.generate(),
          project_id: post_a.project_id,
          post_id_a: sorted_a,
          post_id_b: sorted_b,
          dismissed_at: System.system_time(:second)
        })
        |> Repo.insert_or_update!()

      {:ok, saved_pair}
    else
      _ -> {:error, :not_found}
    end
  end

  defp source_post_and_vector(post_id) do
    with {:ok, post} <- fetch_post(post_id) do
      if enabled_for_project?(post.project_id) do
        :ok = ensure_key(post)

        case Repo.get_by(Key, post_id: post.id, project_id: post.project_id) do
          nil -> {:ok, post, []}
          key -> {:ok, post, decode_vector(key.vector)}
        end
      else
        {:disabled, post.project_id}
      end
    end
  end

  defp ensure_key(%Post{} = post) do
    case Repo.get_by(Key, post_id: post.id, project_id: post.project_id) do
      nil -> sync_post(post)
      _key -> :ok
    end
  end

  defp fetch_post(post_id) do
    case Repo.get(Post, post_id) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp enabled_for_project?(project_id) do
    case Metadata.get_project_metadata(project_id) do
      {:ok, metadata} -> metadata.semantic_similarity_enabled == true
      _other -> false
    end
  end

  defp existing_key_label(nil), do: nil
  defp existing_key_label(%Key{label: label}), do: label

  defp configured_backend do
    Application.get_env(:bds, :embeddings, [])
    |> Keyword.get(:backend, BDS.Embeddings.Backends.InApp)
  end

  defp next_label do
    Repo.one(from key in Key, select: max(key.label))
    |> case do
      nil -> 1
      value -> value + 1
    end
  end

  defp resolve_post_body(%Post{content: content}) when is_binary(content) and content != "", do: content

  defp resolve_post_body(%Post{project_id: project_id, file_path: file_path}) do
    if file_path in [nil, ""] do
      ""
    else
      project = Projects.get_project!(project_id)
      full_path = Path.join(Projects.project_data_dir(project), file_path)

      case File.read(full_path) do
        {:ok, contents} ->
          case String.split(contents, "\n---\n", parts: 2) do
            [_frontmatter, body] -> String.trim_trailing(body, "\n")
            _parts -> contents
          end

        {:error, _reason} ->
          ""
      end
    end
  end

  defp compose_embedding_source(title, content), do: "#{title || ""}\n\n#{content || ""}"

  defp embed_text(raw_text, language) do
    configured_backend().embed("query: " <> raw_text, language: language)
  end

  defp hash_text(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp decode_vector(nil), do: []
  defp decode_vector(vector), do: Jason.decode!(vector)

  defp cosine_similarity([], _other), do: 0.0
  defp cosine_similarity(_vector, []), do: 0.0

  defp cosine_similarity(left, right) do
    Enum.zip(left, right)
    |> Enum.reduce(0.0, fn {left_value, right_value}, acc -> acc + left_value * right_value end)
    |> max(0.0)
  end

  defp dismissed_pair_keys(project_id) do
    Repo.all(
      from pair in DismissedDuplicatePair,
        where: pair.project_id == ^project_id,
        select: {pair.post_id_a, pair.post_id_b}
    )
    |> MapSet.new(fn {post_id_a, post_id_b} -> pair_key(post_id_a, post_id_b) end)
  end

  defp pair_key(post_id_a, post_id_b) do
    {sorted_a, sorted_b} = sort_pair(post_id_a, post_id_b)
    "#{sorted_a}::#{sorted_b}"
  end

  defp sort_pair(post_id_a, post_id_b) when post_id_a <= post_id_b, do: {post_id_a, post_id_b}
  defp sort_pair(post_id_a, post_id_b), do: {post_id_b, post_id_a}
end
