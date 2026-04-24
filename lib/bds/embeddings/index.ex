defmodule BDS.Embeddings.Index do
  @moduledoc false

  import Ecto.Query

  alias BDS.Embeddings.Key
  alias BDS.Projects
  alias BDS.Repo

  @neighbor_limit 21

  def path(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)
    Path.join(Projects.project_data_dir(project), "embeddings.usearch")
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
      "updated_at" => System.system_time(:second),
      "entries" => entries
    }

    write_snapshot(path(project_id), payload)
  end

  def read(project_id) when is_binary(project_id) do
    snapshot_path = path(project_id)

    case File.read(snapshot_path) do
      {:ok, contents} -> {:ok, Jason.decode!(contents)}
      {:error, :enoent} -> read_legacy_snapshot(project_id)
      {:error, reason} -> {:error, reason}
    end
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

  def duplicate_pairs(project_id, threshold) when is_binary(project_id) do
    with {:ok, snapshot} <- read(project_id) do
      pairs =
        snapshot
        |> Map.get("entries", %{})
        |> Enum.flat_map(fn {post_id, entry} ->
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

  defp write_snapshot(snapshot_path, payload) do
    :ok = File.mkdir_p(Path.dirname(snapshot_path))
    temp_path = snapshot_path <> ".tmp"
    :ok = File.write(temp_path, Jason.encode!(payload))
    :ok = File.rename(temp_path, snapshot_path)
    legacy_path = legacy_path(snapshot_path)

    if File.exists?(legacy_path) do
      File.rm(legacy_path)
    end

    :ok
  end

  defp read_legacy_snapshot(project_id) do
    legacy_snapshot_path = project_id |> path() |> legacy_path()

    case File.read(legacy_snapshot_path) do
      {:ok, contents} -> {:ok, Jason.decode!(contents)}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_path(snapshot_path) do
    Path.join(Path.dirname(snapshot_path), "embeddings.index.json")
  end

  defp decode_vector(nil), do: []
  defp decode_vector(vector), do: Jason.decode!(vector)

  defp cosine_similarity([], _other), do: 0.0
  defp cosine_similarity(_vector, []), do: 0.0

  defp cosine_similarity(left, right) do
    Enum.zip(left, right)
    |> Enum.reduce(0.0, fn {left_value, right_value}, acc -> acc + left_value * right_value end)
    |> max(0.0)
  end

  defp sort_pair(post_id_a, post_id_b) when post_id_a <= post_id_b, do: {post_id_a, post_id_b}
  defp sort_pair(post_id_a, post_id_b), do: {post_id_b, post_id_a}
end
