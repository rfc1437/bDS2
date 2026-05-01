defmodule BDS.Maintenance.Repair do
  @moduledoc false

  import BDS.Maintenance.FileScan,
    only: [
      canonical_media_sidecar?: 1,
      translation_post_file?: 1,
      translation_media_sidecar?: 1
    ]

  import BDS.Maintenance.Progress, only: [report_progress: 4]

  alias BDS.Embeddings
  alias BDS.MapUtils
  alias BDS.Metadata

  def normalize_entity_type(:post), do: :post
  def normalize_entity_type(:media), do: :media
  def normalize_entity_type(:script), do: :script
  def normalize_entity_type(:template), do: :template
  def normalize_entity_type(:embedding), do: :embedding
  def normalize_entity_type("post"), do: :post
  def normalize_entity_type("media"), do: :media
  def normalize_entity_type("script"), do: :script
  def normalize_entity_type("template"), do: :template
  def normalize_entity_type("embedding"), do: :embedding
  def normalize_entity_type("embeddings"), do: :embedding
  def normalize_entity_type(_entity_type), do: :unsupported

  def normalize_repair_direction(:file_to_db), do: :file_to_db
  def normalize_repair_direction(:db_to_file), do: :db_to_file
  def normalize_repair_direction("file_to_db"), do: :file_to_db
  def normalize_repair_direction("db_to_file"), do: :db_to_file
  def normalize_repair_direction(_direction), do: :unsupported

  def repair_metadata_diff_item(project_id, direction, item) do
    entity_type = MapUtils.attr(item, :entity_type)
    entity_id = MapUtils.attr(item, :entity_id)

    case {normalize_repair_direction(direction), entity_type} do
      {:file_to_db, entity_type}
      when entity_type in ["project", "categories", "category_meta", "publishing"] ->
        Metadata.sync_project_metadata_from_filesystem(project_id)

      {:db_to_file, entity_type}
      when entity_type in ["project", "categories", "category_meta", "publishing"] ->
        Metadata.flush_project_metadata_to_filesystem(project_id)

      {:file_to_db, "post"} ->
        BDS.Posts.sync_post_from_file(entity_id)

      {:db_to_file, "post"} ->
        BDS.Posts.rewrite_published_post(entity_id)

      {:file_to_db, "post_translation"} ->
        BDS.Posts.sync_post_translation_from_file(entity_id)

      {:db_to_file, "post_translation"} ->
        BDS.Posts.rewrite_published_post_translation(entity_id)

      {:file_to_db, "media"} ->
        BDS.Media.sync_media_from_sidecar(entity_id)

      {:db_to_file, "media"} ->
        BDS.Media.sync_media_sidecar(entity_id)

      {:file_to_db, "media_translation"} ->
        BDS.Media.sync_media_translation_from_sidecar(entity_id)

      {:db_to_file, "media_translation"} ->
        BDS.Media.sync_media_translation_sidecar(entity_id)

      {:file_to_db, "script"} ->
        BDS.Scripts.sync_script_from_file(entity_id)

      {:db_to_file, "script"} ->
        BDS.Scripts.sync_published_script_file(entity_id)

      {:file_to_db, "template"} ->
        BDS.Templates.sync_template_from_file(entity_id)

      {:db_to_file, "template"} ->
        BDS.Templates.sync_published_template_file(entity_id)

      {:file_to_db, "embedding"} ->
        BDS.Embeddings.sync_post(entity_id)

      {:db_to_file, "embedding"} ->
        BDS.Embeddings.refresh_snapshot(project_id)

      _other ->
        {:error, :unsupported}
    end
  end

  def repair_embedding_batch(project_id, direction, items, on_progress, total)
      when direction in [:file_to_db, :db_to_file] do
    if items != [] and Enum.all?(items, &(metadata_diff_item_entity_type(&1) == "embedding")) do
      result =
        case direction do
          :file_to_db ->
            post_ids = Enum.map(items, &metadata_diff_item_entity_id/1)

            {:ok, repaired_post_ids} = Embeddings.repair_posts(project_id, post_ids)
            repaired_post_ids = MapSet.new(repaired_post_ids)

            build_batch_repair_result(items, total, on_progress, fn item ->
              MapSet.member?(repaired_post_ids, metadata_diff_item_entity_id(item))
            end)

          :db_to_file ->
            repaired? = Embeddings.refresh_snapshot(project_id) == :ok
            build_batch_repair_result(items, total, on_progress, fn _item -> repaired? end)
        end

      {:ok, result}
    else
      :unsupported
    end
  end

  def repair_embedding_batch(_project_id, _direction, _items, _on_progress, _total),
    do: :unsupported

  defp build_batch_repair_result(items, total, on_progress, repaired?) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce(%{repaired: 0, failed: 0}, fn {item, index}, acc ->
      next_acc =
        if repaired?.(item) do
          %{acc | repaired: acc.repaired + 1}
        else
          %{acc | failed: acc.failed + 1}
        end

      :ok = report_progress(on_progress, index, total, "Repairing metadata differences")
      next_acc
    end)
  end

  defp metadata_diff_item_entity_type(item) do
    MapUtils.attr(item, :entity_type)
  end

  defp metadata_diff_item_entity_id(item) do
    MapUtils.attr(item, :entity_id)
  end

  def import_metadata_diff_orphan(project_id, orphan) do
    file_path = MapUtils.attr(orphan, :file_path)

    cond do
      is_nil(file_path) ->
        {:error, :not_found}

      translation_post_file?(file_path) ->
        BDS.Posts.import_orphan_post_translation_file(project_id, file_path)

      String.ends_with?(file_path, ".md") ->
        BDS.Posts.import_orphan_post_file(project_id, file_path)

      translation_media_sidecar?(file_path) ->
        BDS.Media.import_orphan_media_translation_sidecar(project_id, file_path)

      canonical_media_sidecar?(file_path) and String.ends_with?(file_path, ".meta") ->
        BDS.Media.import_orphan_media_sidecar(project_id, file_path)

      String.ends_with?(file_path, ".lua") ->
        BDS.Scripts.import_orphan_script_file(project_id, file_path)

      String.ends_with?(file_path, ".liquid") ->
        BDS.Templates.import_orphan_template_file(project_id, file_path)

      true ->
        {:error, :unsupported}
    end
  end
end
