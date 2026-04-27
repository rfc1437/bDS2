defmodule BDS.Embeddings do
  @moduledoc false

  import Ecto.Query

  alias BDS.Persistence
  alias BDS.Embeddings.DismissedDuplicatePair
  alias BDS.Embeddings.Index
  alias BDS.Embeddings.Key
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  @duplicate_threshold 0.92
  @exact_match_score 0.999999

  def model_id, do: configured_backend().model_info().model_id
  def dimensions, do: configured_backend().model_info().dimensions
  def index_path(project_id), do: Index.path(project_id)
  def reindex_all(project_id), do: rebuild_project(project_id)

  def refresh_snapshot(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      :ok = rebuild_snapshot(project_id)
    end

    :ok
  end

  def get_indexing_progress(project_id) when is_binary(project_id) do
    indexed =
      Repo.one(
        from key in Key,
          where: key.project_id == ^project_id,
          select: count(key.post_id, :distinct)
      ) || 0

    total =
      Repo.one(
        from post in Post,
          where: post.project_id == ^project_id,
          select: count(post.id)
      ) || 0

    {:ok, %{indexed: indexed, total: total}}
  end

  def sync_post(%Post{} = post) do
    if enabled_for_project?(post.project_id) do
      sync_post_if_enabled(post, refresh_index: true)
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

  def repair_posts(project_id, post_ids) when is_binary(project_id) and is_list(post_ids) do
    if enabled_for_project?(project_id) do
      post_ids = Enum.uniq(post_ids)

      posts =
        Repo.all(
          from post in Post,
            where: post.project_id == ^project_id and post.id in ^post_ids,
            order_by: [asc: post.created_at, asc: post.slug]
        )

      Enum.each(posts, &sync_post_if_enabled(&1, refresh_index: false))
      :ok = rebuild_snapshot(project_id)
      {:ok, Enum.map(posts, & &1.id)}
    else
      {:ok, []}
    end
  end

  def rebuild_project(project_id, opts \\ [])

  def rebuild_project(project_id, opts) when is_binary(project_id) and is_list(opts) do
    if enabled_for_project?(project_id) do
      on_progress = progress_callback(opts)

      posts =
        Repo.all(from post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at, asc: post.slug])

      post_ids = Enum.map(posts, & &1.id)
      total_posts = length(posts)

      :ok = report_rebuild_started(on_progress, total_posts, "embedding entries")

      Repo.delete_all(
        from key in Key,
          where: key.project_id == ^project_id and key.post_id not in ^post_ids
      )

      posts
      |> Enum.with_index(1)
      |> Enum.each(fn {post, index} ->
        sync_post_if_enabled(post, refresh_index: false)
        :ok = report_rebuild_progress(on_progress, index, total_posts, "embedding entries")
      end)

      :ok = report_rebuild_phase(on_progress, 0.99, "Persisting embedding snapshot")
      :ok = rebuild_snapshot(project_id)
      {:ok, post_ids}
    else
      {:ok, []}
    end
  end

  def diff_reports(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      keys_by_post =
        Repo.all(from key in Key, where: key.project_id == ^project_id)
        |> Map.new(&{&1.post_id, &1})

      Repo.all(from post in Post, where: post.project_id == ^project_id)
      |> Enum.flat_map(fn post ->
        expected_hash = post_content_hash(post)
        key = Map.get(keys_by_post, post.id)

        differences =
          [
            diff_field("content_hash", key && key.content_hash, expected_hash),
            diff_field(
              "embedding",
              current_embedding_status(key, expected_hash),
              expected_embedding_status(key, expected_hash)
            )
          ]
          |> Enum.reject(&is_nil/1)

        if differences == [] do
          []
        else
          [
            %{
              entity_type: "embedding",
              entity_id: post.id,
              label: post.title || post.slug || post.id,
              meta_label: Persistence.timestamp_to_iso8601(post.created_at),
              differences: differences
            }
          ]
        end
      end)
    else
      []
    end
  end

  defp sync_post_if_enabled(%Post{} = post, opts) do
    body = resolve_post_body(post)
    raw_text = compose_embedding_source(post.title, body)
    content_hash = hash_text(raw_text)

    case Repo.get_by(Key, post_id: post.id, project_id: post.project_id) do
      %Key{content_hash: ^content_hash} ->
        if Keyword.get(opts, :refresh_index, true) and snapshot_content_hash(post.project_id, post.id) != content_hash do
          :ok = rebuild_snapshot(post.project_id)
        end

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

        if Keyword.get(opts, :refresh_index, true) do
          :ok = rebuild_snapshot(post.project_id)
        end

        :ok
    end
  end

  def remove_post(post_id) when is_binary(post_id) do
    project_id =
      case Repo.get_by(Key, post_id: post_id) do
        %Key{project_id: project_id} -> project_id
        nil -> case Repo.get(Post, post_id) do
          %Post{project_id: project_id} -> project_id
          nil -> nil
        end
      end

    Repo.delete_all(from key in Key, where: key.post_id == ^post_id)

    if is_binary(project_id) and enabled_for_project?(project_id) do
      :ok = rebuild_snapshot(project_id)
    end

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
              :ok =
                sync_post_if_enabled(
                  %{post | content: if(post.content in [nil, ""], do: body, else: post.content)},
                  refresh_index: false
                )
          end
        end)

      :ok = rebuild_snapshot(project_id)

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
          case Index.neighbors(post.project_id, post.id, limit) do
            {:ok, neighbors} -> neighbors
            {:error, :missing} ->
              Repo.all(from key in Key, where: key.project_id == ^post.project_id and key.post_id != ^post.id)
              |> Enum.map(fn key -> %{post_id: key.post_id, score: cosine_similarity(source_vector, decode_vector(key.vector))} end)
              |> Enum.sort_by(& &1.score, :desc)
              |> Enum.take(max(limit, 0))
          end

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
    end
  end

  def find_duplicates(project_id, opts \\ []) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      on_progress = progress_callback(opts)
      dismissed = dismissed_pair_keys(project_id)

      duplicates =
        case Index.duplicate_pairs(project_id, @duplicate_threshold, on_progress: on_progress) do
          {:ok, pairs} ->
            pairs
            |> Enum.reject(fn pair -> pair_key(pair.post_id_a, pair.post_id_b) in dismissed end)
            |> enrich_duplicate_pairs(project_id)

          {:error, :missing} ->
            keys = Repo.all(from key in Key, where: key.project_id == ^project_id, order_by: [asc: key.post_id])
            total_keys = length(keys)

            :ok = report_rebuild_started(on_progress, total_keys, "embedding entries")

            keys
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {left, index} ->
              :ok = report_rebuild_progress(on_progress, index, total_keys, "embedding entries")

              for right <- keys,
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
            end)
            |> enrich_duplicate_pairs(project_id)
        end

      :ok = report_rebuild_phase(on_progress, 0.99, "Resolving duplicate candidates")
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
          dismissed_at: Persistence.now_ms()
        })
        |> Repo.insert_or_update!()

      {:ok, saved_pair}
    else
      _ -> {:error, :not_found}
    end
  end

  def dismiss_duplicate_pairs(pair_ids) when is_list(pair_ids) do
    pair_ids
    |> Enum.filter(fn
      {post_id_a, post_id_b} when is_binary(post_id_a) and is_binary(post_id_b) -> true
      _other -> false
    end)
    |> Enum.map(fn {post_id_a, post_id_b} -> sort_pair(post_id_a, post_id_b) end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn {post_id_a, post_id_b}, {:ok, acc} ->
      case dismiss_duplicate_pair(post_id_a, post_id_b) do
        {:ok, saved_pair} -> {:cont, {:ok, [saved_pair | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, saved_pairs} -> {:ok, Enum.reverse(saved_pairs)}
      {:error, reason} -> {:error, reason}
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

  defp enrich_duplicate_pairs(pairs, project_id) do
    posts_by_id =
      pairs
      |> Enum.flat_map(&[&1.post_id_a, &1.post_id_b])
      |> Enum.uniq()
      |> then(fn post_ids ->
        Repo.all(from post in Post, where: post.project_id == ^project_id and post.id in ^post_ids)
        |> Map.new(&{&1.id, &1})
      end)

    pairs
    |> Enum.map(fn pair ->
      post_a = Map.fetch!(posts_by_id, pair.post_id_a)
      post_b = Map.fetch!(posts_by_id, pair.post_id_b)
      exact_match = exact_duplicate_match?(pair.score, post_a, post_b)

      pair
      |> Map.put(:title_a, post_a.title || "")
      |> Map.put(:title_b, post_b.title || "")
      |> Map.put(:similarity, pair.score)
      |> Map.put(:exact_match, exact_match)
    end)
    |> Enum.sort_by(fn pair -> {not pair.exact_match, -pair.score, pair.post_id_a, pair.post_id_b} end)
  end

  defp exact_duplicate_match?(score, %Post{} = post_a, %Post{} = post_b) do
    score >= @exact_match_score and
      (post_a.title || "") == (post_b.title || "") and
      resolve_post_body(post_a) == resolve_post_body(post_b)
  end

  defp enabled_for_project?(project_id) do
    case Metadata.get_project_metadata(project_id) do
      {:ok, metadata} -> metadata.semantic_similarity_enabled == true
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

  defp compose_embedding_source(title, content), do: string_or_empty(title) <> "\n\n" <> string_or_empty(content)

  defp string_or_empty(nil), do: ""
  defp string_or_empty(value) when is_binary(value), do: value

  defp post_content_hash(%Post{} = post) do
    body = resolve_post_body(post)
    hash_text(compose_embedding_source(post.title, body))
  end

  defp embed_text(raw_text, language) do
    configured_backend().embed("query: " <> raw_text, language: language)
  end

  defp rebuild_snapshot(project_id) do
    Index.rebuild(project_id, model_id: model_id(), dimensions: dimensions())
  end

  defp progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  defp report_rebuild_started(nil, _total, _label), do: :ok

  defp report_rebuild_started(callback, 0, label) do
    callback.(1.0, "No #{label} to rebuild")
    :ok
  end

  defp report_rebuild_started(callback, total, label) do
    callback.(0.0, "Rebuilding 0/#{total} #{label}")
    :ok
  end

  defp report_rebuild_progress(nil, _current, _total, _label), do: :ok
  defp report_rebuild_progress(_callback, _current, 0, _label), do: :ok

  defp report_rebuild_progress(callback, current, total, label) do
    callback.(current / total, "Rebuilding #{current}/#{total} #{label}")
    :ok
  end

  defp report_rebuild_phase(nil, _value, _label), do: :ok

  defp report_rebuild_phase(callback, value, label) do
    callback.(value, label)
    :ok
  end

  defp snapshot_content_hash(project_id, post_id) do
    case Index.read(project_id) do
      {:ok, snapshot} -> get_in(snapshot, ["entries", post_id, "content_hash"])
      _other -> nil
    end
  end

  defp current_embedding_status(nil, _expected_hash), do: "missing"

  defp current_embedding_status(%Key{vector: vector}, _expected_hash) when vector in [nil, ""],
    do: "missing"

  defp current_embedding_status(%Key{content_hash: content_hash}, expected_hash)
       when content_hash != expected_hash,
       do: "stale"

  defp current_embedding_status(%Key{}, _expected_hash), do: "ready"

  defp expected_embedding_status(key, expected_hash) do
    case current_embedding_status(key, expected_hash) do
      "ready" -> "ready"
      _other -> "re-embed required"
    end
  end

  defp diff_field(name, db_value, file_value) do
    db_value = normalize_diff_value(db_value)
    file_value = normalize_diff_value(file_value)

    if db_value == file_value do
      nil
    else
      %{name: name, db_value: db_value, file_value: file_value}
    end
  end

  defp normalize_diff_value(value) when is_binary(value), do: value
  defp normalize_diff_value(nil), do: ""
  defp normalize_diff_value(value), do: value

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
