defmodule BDS.Media.Rebuilder do
  @moduledoc false

  import BDS.Media.FileOps,
    only: [
      list_matching_files: 2,
      progress_callback: 1,
      report_rebuild_phase: 3,
      report_rebuild_progress: 4,
      report_rebuild_started: 3,
      scaled_progress_reporter: 3
    ]

  alias BDS.Media.Media
  alias BDS.Media.Sidecars
  alias BDS.Projects
  alias BDS.Rebuild
  alias BDS.Search

  @type rebuild_opts :: keyword()

  @spec rebuild_media_from_files(String.t(), rebuild_opts()) :: {:ok, [Media.t()]}
  def rebuild_media_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    canonical_sidecars =
      project
      |> Projects.project_data_dir()
      |> Path.join("media")
      |> list_matching_files("*.meta")
      |> Enum.filter(&Sidecars.canonical_sidecar?/1)
      |> Enum.filter(&Sidecars.binary_exists_for_sidecar?/1)
      |> Rebuild.parallel_map(&Sidecars.parse_canonical_sidecar(project, &1))

    translation_sidecars =
      project
      |> Projects.project_data_dir()
      |> Path.join("media")
      |> list_matching_files("*.meta")
      |> Enum.filter(&Sidecars.translation_sidecar?/1)
      |> Rebuild.parallel_map(&Sidecars.parse_translation_sidecar(&1))

    total_files = length(canonical_sidecars) + length(translation_sidecars)
    :ok = report_rebuild_started(on_progress, total_files, "media files")

    media_items =
      canonical_sidecars
      |> Enum.with_index(1)
      |> Enum.map(fn {sidecar, index} ->
        media = Sidecars.upsert_media_from_sidecar(project, sidecar, sync_search: false)
        :ok = report_rebuild_progress(on_progress, index, total_files, "media files")
        media
      end)

    canonical_media_by_binary_path =
      Map.new(media_items, fn media ->
        {Path.join(Projects.project_data_dir(project), media.file_path), media}
      end)

    translation_sidecars
    |> Enum.with_index(length(canonical_sidecars) + 1)
    |> Enum.each(fn {sidecar, index} ->
      Sidecars.upsert_translation_from_sidecar(project, canonical_media_by_binary_path, sidecar,
        sync_search: false
      )

      :ok = report_rebuild_progress(on_progress, index, total_files, "media files")
    end)

    if Keyword.get(opts, :reindex_search, true) do
      :ok = report_rebuild_phase(on_progress, 0.99, "Refreshing media search index")

      :ok =
        Search.reindex_media(project.id,
          on_progress: scaled_progress_reporter(on_progress, 0.99, 1.0)
        )
    end

    {:ok, media_items}
  end
end
