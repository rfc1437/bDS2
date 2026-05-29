defmodule BDS.Embeddings.Index do
  @moduledoc false

  import Ecto.Query

  alias BDS.Persistence
  alias BDS.Embeddings.Key
  alias BDS.Projects
  alias BDS.ProgressReporter
  alias BDS.Repo

  @neighbor_limit 21

  def path(project_id) when is_binary(project_id) do
    Path.join(Projects.project_cache_dir(project_id), "embeddings.usearch")
  end

  def rebuild(project_id, opts) when is_binary(project_id) and is_list(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    dimensions = Keyword.fetch!(opts, :dimensions)

    keys =
      Repo.all(
        from key in Key,
          where: key.project_id == ^project_id,
          order_by: [asc: key.post_id]
      )

    entries =
      keys
      |> Enum.map(fn key ->
        vector = decode_vector(key.vector)

        {key.post_id,
         %{
           "label" => key.label,
           "content_hash" => key.content_hash,
           "neighbors" => neighbor_entries(keys, key, vector)
         }}
      end)
      |> Map.new()

    payload = %{
      "project_id" => project_id,
      "model_id" => model_id,
      "dimensions" => dimensions,
      "updated_at" => Persistence.now_ms(),
      "entries" => entries
    }

    write_snapshot(path(project_id), payload, project_id)
  end

  def read(project_id) when is_binary(project_id) do
    project_id
    |> candidate_paths()
    |> read_snapshot_paths()
  end

  def neighbors(project_id, post_id, limit) when is_binary(project_id) and is_binary(post_id) do
    with {:ok, snapshot} <- read(project_id),
         %{} = entry <- get_in(snapshot, ["entries", post_id]) do
      entry
      |> Map.get("neighbors", [])
      |> Enum.take(max(limit, 0))
      |> Enum.map(fn neighbor ->
        %{
          post_id: neighbor["post_id"],
          score: neighbor["score"]
        }
      end)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :missing}
    end
  end

  def duplicate_pairs(project_id, threshold, opts \\ []) when is_binary(project_id) do
    with {:ok, snapshot} <- read(project_id) do
      entries = Map.get(snapshot, "entries", %{})
      entry_count = map_size(entries)
      on_progress = progress_callback(opts)

      :ok = report_scan_started(on_progress, entry_count, "embedding entries")

      pairs =
        entries
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {{post_id, entry}, index} ->
          :ok = report_scan_progress(on_progress, index, entry_count, "embedding entries")

          entry
          |> Map.get("neighbors", [])
          |> Enum.filter(&(&1["score"] >= threshold))
          |> Enum.map(fn neighbor ->
            {post_id_a, post_id_b} = sort_pair(post_id, neighbor["post_id"])

            {{post_id_a, post_id_b},
             %{
               post_id_a: post_id_a,
               post_id_b: post_id_b,
               score: neighbor["score"]
             }}
          end)
        end)
        |> Map.new()
        |> Map.values()
        |> Enum.sort_by(& &1.score, :desc)

      {:ok, pairs}
    else
      _ -> {:error, :missing}
    end
  end

  defp neighbor_entries(keys, current_key, current_vector) do
    keys
    |> Enum.reject(&(&1.post_id == current_key.post_id))
    |> Enum.map(fn other_key ->
      %{
        "post_id" => other_key.post_id,
        "label" => other_key.label,
        "score" => cosine_similarity(current_vector, decode_vector(other_key.vector))
      }
    end)
    |> Enum.sort_by(& &1["score"], :desc)
    |> Enum.take(@neighbor_limit)
  end

  defp write_snapshot(snapshot_path, payload, project_id) do
    :ok = Persistence.atomic_write(snapshot_path, Jason.encode!(payload))
    legacy_path = legacy_path(snapshot_path)

    if File.exists?(legacy_path) do
      File.rm(legacy_path)
    end

    cleanup_legacy_project_snapshots(project_id, snapshot_path)

    :ok
  end

  defp candidate_paths(project_id) do
    current_snapshot_path = path(project_id)
    legacy_project_snapshot_path = legacy_project_snapshot_path(project_id)

    [
      current_snapshot_path,
      legacy_path(current_snapshot_path),
      legacy_project_snapshot_path,
      legacy_project_snapshot_path && legacy_path(legacy_project_snapshot_path)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp read_snapshot_paths([]), do: {:error, :missing}

  defp read_snapshot_paths([snapshot_path | rest]) do
    case File.read(snapshot_path) do
      {:ok, contents} -> {:ok, Jason.decode!(contents)}
      {:error, :enoent} -> read_snapshot_paths(rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_legacy_project_snapshots(project_id, snapshot_path) do
    current_paths = [snapshot_path, legacy_path(snapshot_path)]

    project_id
    |> legacy_project_snapshot_path()
    |> then(fn legacy_snapshot_path ->
      [legacy_snapshot_path, legacy_snapshot_path && legacy_path(legacy_snapshot_path)]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 in current_paths))
    |> Enum.each(fn legacy_snapshot_path ->
      if File.exists?(legacy_snapshot_path) do
        File.rm(legacy_snapshot_path)
      end
    end)
  end

  defp legacy_project_snapshot_path(project_id) do
    case Projects.get_project(project_id) do
      nil -> nil
      project -> Path.join(Projects.project_data_dir(project), "embeddings.usearch")
    end
  end

  defp legacy_path(snapshot_path) do
    Path.join(Path.dirname(snapshot_path), "embeddings.index.json")
  end

  # Vectors are stored as a packed little-endian Float32 BLOB; see
  # BDS.Embeddings and the VectorCacheInDb invariant in embedding.allium.
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

  defp sort_pair(post_id_a, post_id_b) when post_id_a <= post_id_b, do: {post_id_a, post_id_b}
  defp sort_pair(post_id_a, post_id_b), do: {post_id_b, post_id_a}

  defp progress_callback(opts), do: ProgressReporter.callback(opts)

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
