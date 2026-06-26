defmodule BDS.Embeddings do
  @moduledoc """
  Context for post embeddings: build and refresh the per-project vector index,
  sync individual posts, report indexing progress, and compute similarity.

  The backing index is persisted to disk and rebuilt on demand; a failed persist
  is retried by the next reindex.
  """

  import Ecto.Query
  require Logger

  @type project_id :: String.t()
  @type post_id :: String.t()
  @type progress_opts :: keyword()
  @type similarity_map :: %{optional(post_id()) => float()}
  @type indexed_posts_result :: {:ok, [post_id()]} | {:error, term()}
  @type duplicate_pair_ids :: [{post_id(), post_id()}]

  alias BDS.Persistence
  alias BDS.Embeddings.DismissedDuplicatePair
  alias BDS.Embeddings.Index
  alias BDS.Embeddings.Key
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.ProgressReporter
  alias BDS.Projects
  alias BDS.Repo

  @duplicate_threshold 0.92
  @exact_match_score 0.999999
  @key_batch_size 199

  @spec model_id() :: term()
  def model_id, do: configured_backend().model_info().model_id

  @spec dimensions() :: pos_integer()
  def dimensions, do: configured_backend().model_info().dimensions

  @spec index_path(project_id()) :: String.t()
  def index_path(project_id), do: Index.path(project_id)

  @spec reindex_all(project_id()) :: indexed_posts_result()
  def reindex_all(project_id), do: rebuild_project(project_id)

  @spec refresh_snapshot(project_id()) :: :ok
  def refresh_snapshot(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      :ok = rebuild_snapshot(project_id)
    end

    :ok
  end

  @spec get_indexing_progress(project_id()) ::
          {:ok, %{indexed: non_neg_integer(), total: non_neg_integer()}}
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

  @spec sync_post(Post.t() | post_id()) :: :ok
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

  @spec repair_posts(project_id(), [post_id()]) :: indexed_posts_result()
  def repair_posts(project_id, post_ids) when is_binary(project_id) and is_list(post_ids) do
    if enabled_for_project?(project_id) do
      post_ids = Enum.uniq(post_ids)

      posts =
        Repo.all(
          from post in Post,
            where: post.project_id == ^project_id and post.id in ^post_ids,
            order_by: [asc: post.created_at, asc: post.slug]
        )

      existing_keys = preload_keys_by_post_id(project_id, Enum.map(posts, & &1.id))

      case build_key_rows(posts, existing_keys, max_label_value(), nil, false) do
        {:ok, rows} ->
          batch_upsert_keys(rows)
          :ok = rebuild_snapshot(project_id)
          {:ok, Enum.map(posts, & &1.id)}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, []}
    end
  end

  @spec rebuild_project(project_id()) :: indexed_posts_result()
  @spec rebuild_project(project_id(), progress_opts()) :: indexed_posts_result()
  def rebuild_project(project_id, opts \\ [])

  def rebuild_project(project_id, opts) when is_binary(project_id) and is_list(opts) do
    if enabled_for_project?(project_id) do
      on_progress = progress_callback(opts)

      posts =
        Repo.all(
          from post in Post,
            where: post.project_id == ^project_id,
            order_by: [asc: post.created_at, asc: post.slug]
        )

      post_ids = Enum.map(posts, & &1.id)

      Repo.delete_all(
        from key in Key,
          where: key.project_id == ^project_id and key.post_id not in ^post_ids
      )

      existing_keys = preload_keys_by_post_id(project_id)

      # An explicit rebuild re-embeds every post from scratch (ReindexAll),
      # ignoring the content_hash skip optimisation.
      case build_key_rows(posts, existing_keys, max_label_value(), on_progress, true) do
        {:ok, rows} ->
          batch_upsert_keys(rows)
          :ok = report_rebuild_phase(on_progress, 0.99, "Persisting embedding snapshot")
          :ok = rebuild_snapshot(project_id)
          {:ok, post_ids}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, []}
    end
  end

  @spec diff_reports(project_id()) :: [map()]
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
        # Embedding is already current. The HNSW index self-heals on query
        # (find_similar/find_duplicates rebuild when no index is loaded), so
        # there is nothing to refresh here.
        :ok

      existing_key ->
        case embed_text(raw_text, post.language) do
          {:ok, vector} ->
            label = existing_key_label(existing_key) || next_label()

            (existing_key || %Key{})
            |> Key.changeset(%{
              label: label,
              post_id: post.id,
              project_id: post.project_id,
              content_hash: content_hash,
              vector: encode_vector(vector)
            })
            |> Repo.insert_or_update()

            if Keyword.get(opts, :refresh_index, true) do
              :ok = rebuild_snapshot(post.project_id)
            end

            :ok

          {:error, reason} ->
            # Embedding is best-effort on post save: if the model is unavailable
            # (e.g. offline first-use download), leave the post unindexed rather
            # than failing the save. An explicit reindex surfaces the error.
            Logger.warning(
              "Embedding unavailable for post #{post.id}: #{inspect(reason)}; left unindexed"
            )

            :ok
        end
    end
  end

  defp preload_keys_by_post_id(project_id) do
    Repo.all(from key in Key, where: key.project_id == ^project_id)
    |> Map.new(&{&1.post_id, &1})
  end

  defp preload_keys_by_post_id(project_id, post_ids) do
    Repo.all(
      from key in Key,
        where: key.project_id == ^project_id and key.post_id in ^post_ids
    )
    |> Map.new(&{&1.post_id, &1})
  end

  defp max_label_value do
    Repo.one(from key in Key, select: max(key.label)) || 0
  end

  # Builds the upsert rows for a batch of posts. Unless `force?` is set, posts
  # whose content_hash is unchanged are skipped (ContentHashSkipsUnchanged); the
  # rest are embedded in batches (see embed_pending/2) so model inference is not
  # serialised one post at a time. Labels keep their existing value or take the
  # next free integer. Returns `{:error, reason}` if the model is unavailable.
  defp build_key_rows(posts, existing_keys, base_label, on_progress, force?) do
    prepared =
      Enum.map(posts, fn post ->
        raw_text = compose_embedding_source(post.title, resolve_post_body(post))
        existing = Map.get(existing_keys, post.id)
        content_hash = hash_text(raw_text)

        %{
          post: post,
          existing: existing,
          raw_text: raw_text,
          content_hash: content_hash,
          needs_embed?: force? or is_nil(existing) or existing.content_hash != content_hash
        }
      end)

    pending = Enum.filter(prepared, & &1.needs_embed?)
    :ok = report_rebuild_started(on_progress, length(pending), "embedding entries")

    case embed_pending(pending, on_progress) do
      {:ok, vectors_by_post_id} -> {:ok, collect_rows(prepared, vectors_by_post_id, base_label)}
      {:error, _reason} = error -> error
    end
  end

  defp collect_rows(prepared, vectors_by_post_id, base_label) do
    {rows, _next_label} =
      Enum.reduce(prepared, {[], base_label + 1}, fn entry, {acc, next_label} ->
        if entry.needs_embed? do
          vector = Map.fetch!(vectors_by_post_id, entry.post.id)
          label = if entry.existing, do: entry.existing.label, else: next_label
          bump = if entry.existing, do: 0, else: 1

          row = [
            label,
            entry.post.id,
            entry.post.project_id,
            entry.content_hash,
            encode_vector(vector)
          ]

          {[row | acc], next_label + bump}
        else
          {acc, next_label}
        end
      end)

    rows
  end

  defp embed_pending([], _on_progress), do: {:ok, %{}}

  defp embed_pending(pending, on_progress) do
    total = length(pending)
    batch = batch_size()

    pending
    # Group by language so the lexical stub stems consistently; the neural
    # backend is multilingual and ignores the language hint.
    |> Enum.group_by(& &1.post.language)
    |> Enum.reduce_while({%{}, 0}, fn {language, group}, acc ->
      group
      |> Enum.chunk_every(batch)
      |> Enum.reduce_while(acc, fn chunk, {vectors, done} ->
        case embed_many(Enum.map(chunk, & &1.raw_text), language) do
          {:ok, chunk_vectors} ->
            vectors =
              chunk
              |> Enum.zip(chunk_vectors)
              |> Enum.reduce(vectors, fn {entry, vector}, acc ->
                Map.put(acc, entry.post.id, vector)
              end)

            done = done + length(chunk)
            :ok = report_rebuild_progress(on_progress, done, total, "embedding entries")
            {:cont, {vectors, done}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:halt, {:error, reason}}
        accumulator -> {:cont, accumulator}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {vectors, _done} -> {:ok, vectors}
    end
  end

  defp batch_upsert_keys([]), do: :ok

  defp batch_upsert_keys(rows) do
    rows
    |> Enum.chunk_every(@key_batch_size)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(chunk, ", ", fn _ -> "(?, ?, ?, ?, ?)" end)
      params = List.flatten(chunk)

      Repo.query!(
        "INSERT INTO embedding_keys (label, post_id, project_id, content_hash, vector) VALUES #{placeholders} ON CONFLICT(label) DO UPDATE SET content_hash = excluded.content_hash, vector = excluded.vector",
        params
      )
    end)
  end

  @spec remove_post(post_id()) :: :ok
  def remove_post(post_id) when is_binary(post_id) do
    project_id =
      case Repo.get_by(Key, post_id: post_id) do
        %Key{project_id: project_id} ->
          project_id

        nil ->
          case Repo.get(Post, post_id) do
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

  @spec index_unindexed(project_id()) :: indexed_posts_result()
  def index_unindexed(project_id) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      posts =
        Repo.all(
          from post in Post,
            where: post.project_id == ^project_id,
            order_by: [asc: post.created_at, asc: post.slug]
        )

      existing_keys = preload_keys_by_post_id(project_id)

      case build_key_rows(posts, existing_keys, max_label_value(), nil, false) do
        {:ok, rows} ->
          batch_upsert_keys(rows)
          :ok = rebuild_snapshot(project_id)

          indexed =
            Repo.all(from key in Key, where: key.project_id == ^project_id, select: key.post_id)

          {:ok, indexed}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, []}
    end
  end

  @spec find_similar(post_id()) :: {:ok, [map()]}
  @spec find_similar(post_id(), pos_integer()) :: {:ok, [map()]}
  def find_similar(post_id, limit \\ 5) when is_binary(post_id) and is_integer(limit) do
    case source_post_and_vector(post_id) do
      {:disabled, _project_id} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:ok, _post, nil} ->
        {:ok, []}

      {:ok, post, %Key{} = key} ->
        {:ok, query_similar(post.project_id, key, limit)}
    end
  end

  # Queries the HNSW index for a post's neighbours, rebuilding the index from
  # the DB vectors if it is not currently loaded (e.g. after a restart).
  defp query_similar(project_id, %Key{} = key, limit) do
    case Index.neighbors(project_id, key.label, key.vector, limit) do
      {:ok, neighbors} ->
        neighbors

      {:error, :missing} ->
        :ok = rebuild_snapshot(project_id)

        case Index.neighbors(project_id, key.label, key.vector, limit) do
          {:ok, neighbors} -> neighbors
          {:error, :missing} -> []
        end
    end
  end

  @spec compute_similarities(post_id(), [post_id()]) :: {:ok, similarity_map()}
  def compute_similarities(source_post_id, target_post_ids)
      when is_binary(source_post_id) and is_list(target_post_ids) do
    case source_post_and_vector(source_post_id) do
      {:disabled, _project_id} ->
        {:ok, %{}}

      {:error, :not_found} ->
        {:ok, %{}}

      {:ok, _post, nil} ->
        {:ok, %{}}

      {:ok, post, %Key{} = source_key} ->
        target_ids = Enum.uniq(target_post_ids)
        source_vector = decode_vector(source_key.vector)

        scores =
          Repo.all(
            from key in Key,
              where: key.project_id == ^post.project_id and key.post_id in ^target_ids
          )
          |> Enum.reduce(%{}, fn key, acc ->
            if key.post_id == source_post_id do
              acc
            else
              Map.put(
                acc,
                key.post_id,
                cosine_similarity(source_vector, decode_vector(key.vector))
              )
            end
          end)

        {:ok, scores}
    end
  end

  @spec suggest_tags(post_id(), term()) :: {:ok, [String.t()]}
  def suggest_tags(post_id, _input_text) when is_binary(post_id) do
    with {:ok, _post} <- fetch_post(post_id),
         {:ok, similar} <- find_similar(post_id, 10) do
      suggestions =
        Repo.all(from other in Post, where: other.id in ^Enum.map(similar, & &1.post_id))
        |> Map.new(&{&1.id, &1})
        |> then(fn posts_by_id ->
          Enum.reduce(similar, %{}, fn %{post_id: similar_post_id, score: score}, acc ->
            case Map.get(posts_by_id, similar_post_id) do
              nil ->
                acc

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

  @spec find_duplicates(project_id()) :: {:ok, [map()]}
  @spec find_duplicates(project_id(), progress_opts()) :: {:ok, [map()]}
  def find_duplicates(project_id, opts \\ []) when is_binary(project_id) do
    if enabled_for_project?(project_id) do
      on_progress = progress_callback(opts)
      dismissed = dismissed_pair_keys(project_id)
      entries = load_index_entries(project_id)

      pairs =
        case duplicate_pairs_with_rebuild(project_id, entries, on_progress) do
          {:ok, pairs} -> pairs
          {:error, :missing} -> []
        end

      duplicates =
        pairs
        |> Enum.reject(fn pair -> pair_key(pair.post_id_a, pair.post_id_b) in dismissed end)
        |> enrich_duplicate_pairs(project_id)

      :ok = report_rebuild_phase(on_progress, 0.99, "Resolving duplicate candidates")
      {:ok, duplicates}
    else
      {:ok, []}
    end
  end

  @spec dismiss_duplicate_pair(post_id(), post_id()) ::
      {:ok, DismissedDuplicatePair.t()} | {:error, :not_found}
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

  @spec dismiss_duplicate_pairs(duplicate_pair_ids()) ::
    {:ok, [DismissedDuplicatePair.t()]} | {:error, term()}
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
        {:ok, post, Repo.get_by(Key, post_id: post.id, project_id: post.project_id)}
      else
        {:disabled, post.project_id}
      end
    end
  end

  defp duplicate_pairs_with_rebuild(project_id, entries, on_progress) do
    case Index.duplicate_pairs(project_id, entries, @duplicate_threshold,
           on_progress: on_progress
         ) do
      {:ok, pairs} ->
        {:ok, pairs}

      {:error, :missing} ->
        :ok = rebuild_snapshot(project_id)
        Index.duplicate_pairs(project_id, entries, @duplicate_threshold, on_progress: on_progress)
    end
  end

  defp load_index_entries(project_id) do
    Repo.all(
      from key in Key,
        where: key.project_id == ^project_id,
        order_by: [asc: key.post_id]
    )
    |> Enum.map(fn key -> %{label: key.label, post_id: key.post_id, vector: key.vector} end)
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
        Repo.all(
          from post in Post, where: post.project_id == ^project_id and post.id in ^post_ids
        )
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
    |> Enum.sort_by(fn pair ->
      {not pair.exact_match, -pair.score, pair.post_id_a, pair.post_id_b}
    end)
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

  defp resolve_post_body(%Post{content: content}) when is_binary(content) and content != "",
    do: content

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

  defp compose_embedding_source(title, content),
    do: string_or_empty(title) <> "\n\n" <> string_or_empty(content)

  defp string_or_empty(nil), do: ""
  defp string_or_empty(value) when is_binary(value), do: value

  defp post_content_hash(%Post{} = post) do
    body = resolve_post_body(post)
    hash_text(compose_embedding_source(post.title, body))
  end

  defp embed_text(raw_text, language) do
    # Per-backend preprocessing (e5 "query: " prefix, pooling, normalisation)
    # is the backend's responsibility — see BDS.Embeddings.Backends.Neural.
    configured_backend().embed(raw_text, language: language)
  end

  # Embeds a batch of texts in one shot. Backends that implement the optional
  # embed_many/2 callback (e.g. the neural backend, which feeds them through the
  # model as a single batched inference run) handle the whole list; others fall
  # back to sequential single embeds.
  defp embed_many(texts, language) do
    backend = configured_backend()

    if function_exported?(backend, :embed_many, 2) do
      backend.embed_many(texts, language: language)
    else
      Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
        case backend.embed(text, language: language) do
          {:ok, vector} -> {:cont, {:ok, [vector | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, vectors} -> {:ok, Enum.reverse(vectors)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp batch_size do
    Application.get_env(:bds, :embeddings, [])
    |> Keyword.get(:batch_size, 16)
    |> max(1)
  end

  defp rebuild_snapshot(project_id) do
    Index.put(project_id, dimensions(), load_index_entries(project_id))
  end

  defp progress_callback(opts), do: ProgressReporter.callback(opts)

  defp report_rebuild_started(callback, total, label) do
    ProgressReporter.report_count_started(callback, total, label,
      verb: "Rebuilding",
      start_progress: 0.0,
      empty_suffix: "to rebuild",
      message_style: :prefix_count
    )
  end

  defp report_rebuild_progress(callback, current, total, label) do
    ProgressReporter.report_count_progress(callback, current, total, label,
      verb: "Rebuilding",
      start_progress: 0.0,
      message_style: :prefix_count
    )
  end

  defp report_rebuild_phase(callback, value, label),
    do: ProgressReporter.report_phase(callback, value, label)

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

  # Vectors are persisted as a packed little-endian Float32 BLOB
  # (`dimensions` * 4 bytes; 1536 bytes for multilingual-e5-small) per the
  # VectorCacheInDb invariant in specs/embedding.allium.
  defp encode_vector(values) when is_list(values) do
    for value <- values, into: <<>>, do: <<float32(value)::float-32-little>>
  end

  defp float32(value) when is_float(value), do: value
  defp float32(value) when is_integer(value), do: value * 1.0

  defp decode_vector(nil), do: []
  defp decode_vector(<<>>), do: []

  defp decode_vector(binary) when is_binary(binary) do
    for <<value::float-32-little <- binary>>, do: value
  end

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
