defmodule BDS.Embeddings.Index do
  @moduledoc """
  Per-project approximate-nearest-neighbour index over post embeddings.

  Backed by an HNSW graph (hnswlib) per the A1-14b / `specs/embedding.allium`
  requirement — cosine space, connectivity M=16, efConstruction=128,
  efSearch=64. This replaces the previous O(n²) brute-force cosine snapshot:
  building is O(n·log n) and queries are O(log n).

  The process is intentionally **database-free**: callers (running in their own
  process, e.g. under the test SQL sandbox) read embedding vectors from the DB
  and hand them in. This GenServer owns only the in-memory HNSW graphs, the
  `label → post_id` maps, and file persistence.

  Persistence (DebouncedPersistence invariant): the index file
  (`embeddings.usearch`) plus a small sidecar holding the dimension and the
  label→post_id map are written behind a 5s debounce, and force-saved on
  project switch / shutdown. On a cold query the index is lazily reloaded from
  those files; if they are absent the caller rebuilds from the DB vectors.
  """

  use GenServer

  alias BDS.Projects
  alias BDS.ProgressReporter

  @neighbor_limit 21
  @debounce_ms 5_000
  @space :cosine
  @m 16
  @ef_construction 128
  @ef_search 64

  # ─── Public API ─────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "On-disk path of the HNSW index file for a project."
  def path(project_id) when is_binary(project_id) do
    Path.join(Projects.project_cache_dir(project_id), "embeddings.usearch")
  end

  @doc """
  (Re)builds the index for a project from the given entries and schedules a
  debounced save. `entries` is a list of `%{label:, post_id:, vector:}` where
  `vector` is the packed little-endian Float32 BLOB.
  """
  def put(project_id, dimensions, entries)
      when is_binary(project_id) and is_integer(dimensions) and is_list(entries) do
    GenServer.call(__MODULE__, {:put, project_id, dimensions, entries}, :infinity)
  end

  @doc """
  Returns up to `limit` nearest neighbours of `query_vector` (the post's packed
  BLOB), excluding `query_label`. `{:error, :missing}` if no index is available.
  """
  def neighbors(project_id, query_label, query_vector, limit)
      when is_binary(project_id) and is_integer(query_label) and is_binary(query_vector) do
    GenServer.call(
      __MODULE__,
      {:neighbors, project_id, query_label, query_vector, limit},
      :infinity
    )
  end

  @doc """
  Finds near-duplicate pairs at/above `threshold` by querying the HNSW graph for
  each entry's neighbours. `{:error, :missing}` if no index is available.
  """
  def duplicate_pairs(project_id, entries, threshold, opts \\ [])
      when is_binary(project_id) and is_list(entries) and is_number(threshold) do
    GenServer.call(
      __MODULE__,
      {:duplicate_pairs, project_id, entries, threshold, opts},
      :infinity
    )
  end

  @doc "Forces a pending save for a project to disk now (e.g. on project switch)."
  def flush(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:flush, project_id}, :infinity)
  end

  @doc "Forces all pending saves to disk now (e.g. on shutdown)."
  def flush_all do
    GenServer.call(__MODULE__, :flush_all, :infinity)
  end

  @doc "Drops the in-memory index for a project (e.g. on project deletion)."
  def forget(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:forget, project_id}, :infinity)
  end

  # ─── GenServer ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, project_id, dimensions, entries}, _from, state) do
    entry = build_entry(dimensions, entries)
    state = state |> Map.put(project_id, entry) |> schedule_save(project_id)
    {:reply, :ok, state}
  end

  def handle_call({:neighbors, project_id, query_label, query_vector, limit}, _from, state) do
    case ensure_loaded(state, project_id) do
      {:ok, %{index: nil}, state} ->
        {:reply, {:error, :missing}, state}

      {:ok, entry, state} ->
        {:reply, {:ok, query_neighbors(entry, query_label, query_vector, limit)}, state}

      {:missing, state} ->
        {:reply, {:error, :missing}, state}
    end
  end

  def handle_call({:duplicate_pairs, project_id, entries, threshold, opts}, _from, state) do
    case ensure_loaded(state, project_id) do
      {:ok, %{index: nil}, state} ->
        {:reply, {:error, :missing}, state}

      {:ok, entry, state} ->
        {:reply, {:ok, scan_duplicates(entry, entries, threshold, opts)}, state}

      {:missing, state} ->
        {:reply, {:error, :missing}, state}
    end
  end

  def handle_call({:flush, project_id}, _from, state) do
    {:reply, :ok, save_now(state, project_id)}
  end

  def handle_call(:flush_all, _from, state) do
    state = Enum.reduce(Map.keys(state), state, &save_now(&2, &1))
    {:reply, :ok, state}
  end

  def handle_call({:forget, project_id}, _from, state) do
    case Map.get(state, project_id) do
      %{timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
      _other -> :ok
    end

    {:reply, :ok, Map.delete(state, project_id)}
  end

  @impl true
  def handle_info({:save, project_id}, state) do
    {:noreply, save_now(state, project_id)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state), &save_now(state, &1))
    :ok
  end

  # ─── Build / query ──────────────────────────────────────────

  defp build_entry(dimensions, []), do: %{index: nil, labels: %{}, dim: dimensions, timer: nil}

  defp build_entry(dimensions, entries) do
    count = length(entries)

    {:ok, index} =
      HNSWLib.Index.new(@space, dimensions, count, m: @m, ef_construction: @ef_construction)

    :ok = HNSWLib.Index.set_ef(index, @ef_search)

    tensor =
      entries
      |> Enum.map(& &1.vector)
      |> IO.iodata_to_binary()
      |> Nx.from_binary(:f32)
      |> Nx.reshape({count, dimensions})

    :ok = HNSWLib.Index.add_items(index, tensor, ids: Enum.map(entries, & &1.label))

    %{
      index: index,
      labels: Map.new(entries, &{&1.label, &1.post_id}),
      dim: dimensions,
      timer: nil
    }
  end

  defp query_neighbors(%{index: index, labels: labels}, query_label, query_vector, limit) do
    case query(index, query_vector, limit + 1) do
      [] ->
        []

      results ->
        results
        |> Enum.reject(fn {label, _score} -> label == query_label end)
        |> Enum.map(fn {label, score} -> %{post_id: Map.get(labels, label), score: score} end)
        |> Enum.reject(&is_nil(&1.post_id))
        |> Enum.take(max(limit, 0))
    end
  end

  defp scan_duplicates(%{index: index, labels: labels}, entries, threshold, opts) do
    on_progress = ProgressReporter.callback(opts)
    total = length(entries)
    :ok = report_scan_started(on_progress, total, "embedding entries")

    entries
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, position} ->
      :ok = report_scan_progress(on_progress, position, total, "embedding entries")

      index
      |> query(entry.vector, @neighbor_limit)
      |> Enum.reject(fn {label, _score} -> label == entry.label end)
      |> Enum.map(fn {label, score} -> {Map.get(labels, label), score} end)
      |> Enum.filter(fn {post_id, score} -> not is_nil(post_id) and score >= threshold end)
      |> Enum.map(fn {other_post_id, score} ->
        {post_id_a, post_id_b} = sort_pair(entry.post_id, other_post_id)
        {{post_id_a, post_id_b}, %{post_id_a: post_id_a, post_id_b: post_id_b, score: score}}
      end)
    end)
    |> Map.new()
    |> Map.values()
    |> Enum.sort_by(& &1.score, :desc)
  end

  # Runs a knn query and returns [{label, similarity}] sorted by descending
  # similarity. Cosine distance is converted to similarity as max(0, 1 - d).
  defp query(index, query_vector, k) do
    case HNSWLib.Index.get_current_count(index) do
      {:ok, count} when count > 0 ->
        clamped = min(k, count)

        case HNSWLib.Index.knn_query(index, query_vector, k: clamped) do
          {:ok, labels, distances} ->
            Enum.zip(
              Nx.to_flat_list(labels),
              Enum.map(Nx.to_flat_list(distances), fn distance -> max(0.0, 1.0 - distance) end)
            )

          {:error, _reason} ->
            []
        end

      _other ->
        []
    end
  end

  # ─── Persistence ────────────────────────────────────────────

  defp schedule_save(state, project_id) do
    entry = Map.fetch!(state, project_id)
    if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)
    timer = Process.send_after(self(), {:save, project_id}, @debounce_ms)
    Map.put(state, project_id, %{entry | timer: timer})
  end

  defp save_now(state, project_id) do
    case Map.get(state, project_id) do
      nil ->
        state

      entry ->
        if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)
        persist(project_id, entry)
        Map.put(state, project_id, %{entry | timer: nil})
    end
  end

  defp persist(_project_id, %{index: nil}), do: :ok

  defp persist(project_id, %{index: index, labels: labels, dim: dim}) do
    index_path = path(project_id)
    File.mkdir_p!(Path.dirname(index_path))
    HNSWLib.Index.save_index(index, index_path)
    write_meta(index_path, dim, labels)
    :ok
  rescue
    _exception -> :ok
  end

  defp write_meta(index_path, dim, labels) do
    payload = %{
      "dim" => dim,
      "labels" => Enum.map(labels, fn {label, post_id} -> [label, post_id] end)
    }

    File.write(meta_path(index_path), Jason.encode!(payload))
  end

  defp ensure_loaded(state, project_id) do
    case Map.get(state, project_id) do
      nil ->
        case load_from_disk(project_id) do
          {:ok, entry} -> {:ok, entry, Map.put(state, project_id, entry)}
          :error -> {:missing, state}
        end

      entry ->
        {:ok, entry, state}
    end
  end

  defp load_from_disk(project_id) do
    index_path = path(project_id)

    with {:ok, %{dim: dim, labels: labels}} <- read_meta(index_path),
         true <- File.exists?(index_path),
         {:ok, index} <- HNSWLib.Index.load_index(@space, dim, index_path) do
      :ok = HNSWLib.Index.set_ef(index, @ef_search)
      {:ok, %{index: index, labels: labels, dim: dim, timer: nil}}
    else
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp read_meta(index_path) do
    with {:ok, contents} <- File.read(meta_path(index_path)),
         {:ok, %{"dim" => dim, "labels" => labels}} <- Jason.decode(contents) do
      {:ok,
       %{
         dim: dim,
         labels: Map.new(labels, fn [label, post_id] -> {label, post_id} end)
       }}
    else
      _other -> :error
    end
  end

  defp meta_path(index_path), do: index_path <> ".meta.json"

  defp sort_pair(post_id_a, post_id_b) when post_id_a <= post_id_b, do: {post_id_a, post_id_b}
  defp sort_pair(post_id_a, post_id_b), do: {post_id_b, post_id_a}

  defp report_scan_started(callback, total, label) do
    ProgressReporter.report_count_started(callback, total, label,
      verb: "Scanning",
      start_progress: 0.0,
      empty_suffix: "to scan",
      message_style: :prefix_count
    )
  end

  defp report_scan_progress(callback, current, total, label) do
    ProgressReporter.report_count_progress(callback, current, total, label,
      verb: "Scanning",
      start_progress: 0.0,
      message_style: :prefix_count
    )
  end
end
