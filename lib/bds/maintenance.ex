defmodule BDS.Maintenance do
  @moduledoc false

  import BDS.Maintenance.Progress,
    only: [
      progress_callback: 1,
      report_metadata_diff_phase: 4,
      report_metadata_diff_complete: 1,
      report_started: 3,
      report_progress: 4
    ]

  import BDS.Maintenance.Repair,
    only: [
      normalize_entity_type: 1,
      normalize_repair_direction: 1,
      repair_metadata_diff_item: 3,
      repair_embedding_batch: 5,
      import_metadata_diff_orphan: 2
    ]

  import BDS.Maintenance.DiffReports,
    only: [
      project_metadata_diff_reports: 1,
      post_diff_reports: 2,
      post_translation_diff_reports: 2,
      media_diff_reports: 2,
      media_translation_diff_reports: 2,
      script_diff_reports: 2,
      template_diff_reports: 2
    ]

  import BDS.Maintenance.FileScan, only: [orphan_reports: 2]

  alias BDS.Embeddings
  alias BDS.Projects

  def repair_metadata_diff(project_id, direction, items, opts \\ [])

  def repair_metadata_diff(project_id, direction, items, opts)
      when is_binary(project_id) and is_list(items) do
    on_progress = progress_callback(opts)
    total = length(items)
    :ok = report_started(on_progress, total, "Repairing metadata differences")

    normalized_direction = normalize_repair_direction(direction)

    result =
      case repair_embedding_batch(project_id, normalized_direction, items, on_progress, total) do
        {:ok, batch_result} ->
          batch_result

        :unsupported ->
          items
          |> Enum.with_index(1)
          |> Enum.reduce(%{repaired: 0, failed: 0}, fn {item, index}, acc ->
            next_acc =
              case repair_metadata_diff_item(project_id, normalized_direction, item) do
                :ok -> %{acc | repaired: acc.repaired + 1}
                {:ok, _value} -> %{acc | repaired: acc.repaired + 1}
                _error -> %{acc | failed: acc.failed + 1}
              end

            :ok = report_progress(on_progress, index, total, "Repairing metadata differences")
            next_acc
          end)
      end

    {:ok, result}
  end

  def import_metadata_diff_orphans(project_id, orphans, opts \\ [])

  def import_metadata_diff_orphans(project_id, orphans, opts)
      when is_binary(project_id) and is_list(orphans) do
    on_progress = progress_callback(opts)
    total = length(orphans)
    :ok = report_started(on_progress, total, "Importing orphan files")

    result =
      orphans
      |> Enum.with_index(1)
      |> Enum.reduce(%{imported: 0, failed: 0}, fn {orphan, index}, acc ->
        next_acc =
          case import_metadata_diff_orphan(project_id, orphan) do
            {:ok, _value} -> %{acc | imported: acc.imported + 1}
            _error -> %{acc | failed: acc.failed + 1}
          end

        :ok = report_progress(on_progress, index, total, "Importing orphan files")
        next_acc
      end)

    {:ok, result}
  end

  def rebuild_from_filesystem(project_id, entity_type, opts \\ []) do
    case normalize_entity_type(entity_type) do
      :post -> BDS.Posts.rebuild_posts_from_files(project_id, opts)
      :media -> BDS.Media.rebuild_media_from_files(project_id, opts)
      :script -> BDS.Scripts.rebuild_scripts_from_files(project_id, opts)
      :template -> BDS.Templates.rebuild_templates_from_files(project_id, opts)
      :embedding -> Embeddings.rebuild_project(project_id, opts)
      :unsupported -> {:error, :unsupported_entity_type}
    end
  end

  def metadata_diff(project_id, opts \\ [])

  def metadata_diff(project_id, opts) when is_binary(project_id) and is_list(opts) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    phases = [
      {"Comparing project metadata", fn -> project_metadata_diff_reports(project_id) end},
      {"Comparing post metadata", fn -> post_diff_reports(project_id, project) end},
      {"Comparing post translations",
       fn -> post_translation_diff_reports(project_id, project) end},
      {"Comparing media metadata", fn -> media_diff_reports(project_id, project) end},
      {"Comparing media translations",
       fn -> media_translation_diff_reports(project_id, project) end},
      {"Comparing script metadata", fn -> script_diff_reports(project_id, project) end},
      {"Comparing template metadata", fn -> template_diff_reports(project_id, project) end},
      {"Comparing embeddings", fn -> Embeddings.diff_reports(project_id) end}
    ]

    total_phases = length(phases) + 1

    diff_reports =
      phases
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{label, fun}, index} ->
        :ok = report_metadata_diff_phase(on_progress, index, total_phases, label)
        fun.()
      end)

    :ok =
      report_metadata_diff_phase(on_progress, total_phases, total_phases, "Scanning orphan files")

    orphan_reports = orphan_reports(project_id, project)
    :ok = report_metadata_diff_complete(on_progress)

    {:ok, %{diff_reports: diff_reports, orphan_reports: orphan_reports}}
  end
end
