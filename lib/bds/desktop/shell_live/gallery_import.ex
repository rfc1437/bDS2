defmodule BDS.Desktop.ShellLive.GalleryImport do
  @moduledoc false

  require Logger

  alias BDS.{AI, Media, Metadata}

  @doc """
  Starts the image import pipeline: for each selected path, imports the file,
  runs AI analysis, updates metadata, links to the post, and translates to
  all configured blog languages.

  Processes images with a concurrency cap via a sliding window.
  """
  @spec start(list(String.t()), String.t(), String.t(), String.t(), integer(), pid()) :: :ok
  def start(paths, project_id, post_id, language, concurrency_limit, parent) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    main_language = metadata.main_language || language
    blog_languages = metadata.blog_languages || []

    translate_targets =
      [main_language | blog_languages]
      |> Enum.reject(&(&1 == language or is_nil(&1)))
      |> Enum.uniq()

    {in_flight, remaining} = Enum.split(paths, concurrency_limit)

    tasks =
      Enum.map(in_flight, fn path ->
        Task.async(fn ->
          process_single_image(path, project_id, post_id, language, translate_targets, parent)
        end)
      end)

    known_refs = MapSet.new(tasks, & &1.ref)

    drain_tasks(
      remaining,
      tasks,
      known_refs,
      project_id,
      post_id,
      language,
      translate_targets,
      parent
    )

    send(parent, {:add_images_complete, length(paths)})
  end

  defp drain_tasks(
         [],
         tasks,
         _known_refs,
         _project_id,
         _post_id,
         _language,
         _translate_targets,
         _parent
       ) do
    Enum.each(tasks, fn task -> Task.await(task, :infinity) end)
  end

  defp drain_tasks(
         [next_path | rest],
         tasks,
         known_refs,
         project_id,
         post_id,
         language,
         translate_targets,
         parent
       ) do
    receive do
      {ref, _result} when is_reference(ref) ->
        if MapSet.member?(known_refs, ref) do
          {_completed_task, remaining_tasks} = pop_task_by_ref(tasks, ref)

          new_task =
            Task.async(fn ->
              process_single_image(
                next_path,
                project_id,
                post_id,
                language,
                translate_targets,
                parent
              )
            end)

          drain_tasks(
            rest,
            [new_task | remaining_tasks],
            MapSet.put(MapSet.delete(known_refs, ref), new_task.ref),
            project_id,
            post_id,
            language,
            translate_targets,
            parent
          )
        else
          drain_tasks(
            [next_path | rest],
            tasks,
            known_refs,
            project_id,
            post_id,
            language,
            translate_targets,
            parent
          )
        end

      {:DOWN, ref, :process, _pid, _reason} when is_reference(ref) ->
        if MapSet.member?(known_refs, ref) do
          {_completed_task, remaining_tasks} = pop_task_by_ref(tasks, ref)

          new_task =
            Task.async(fn ->
              process_single_image(
                next_path,
                project_id,
                post_id,
                language,
                translate_targets,
                parent
              )
            end)

          drain_tasks(
            rest,
            [new_task | remaining_tasks],
            MapSet.put(MapSet.delete(known_refs, ref), new_task.ref),
            project_id,
            post_id,
            language,
            translate_targets,
            parent
          )
        else
          drain_tasks(
            [next_path | rest],
            tasks,
            known_refs,
            project_id,
            post_id,
            language,
            translate_targets,
            parent
          )
        end
    end
  end

  defp pop_task_by_ref(tasks, ref) do
    Enum.reduce(tasks, {nil, []}, fn
      %{ref: ^ref} = task, {nil, rest} -> {task, rest}
      task, {found, rest} -> {found, [task | rest]}
    end)
  end

  defp process_single_image(
         path,
         project_id,
         post_id,
         language,
         translate_targets,
         parent
       ) do
    # Linking is mandatory and MUST happen regardless of AI availability
    # (airplane mode / no local model), mirroring the drag-drop chain and the
    # old app: import -> link -> (optional) AI enrichment. Gating the link
    # behind AI is what left galleries empty.
    with {:ok, media} <- Media.import_media(%{project_id: project_id, source_path: path}),
         true <- String.starts_with?(media.mime_type || "", "image/"),
         {:ok, _link} <- Media.link_media_to_post(media.id, post_id) do
      title = enrich_media(media, language, translate_targets)
      send(parent, {:add_image_processed, title})
    else
      false ->
        :ok

      {:error, reason} ->
        Logger.warning("Image pipeline error for #{path}: #{inspect(reason)}")
        send(parent, {:add_image_error, path, reason})
    end
  end

  # Best-effort AI enrichment: analysis + metadata update + translations. Any
  # failure (offline, no model) is logged and never unlinks the image. Returns
  # the display title used for progress reporting.
  defp enrich_media(media, language, translate_targets) do
    case AI.analyze_image(media.id, language: language) do
      {:ok, result} ->
        case Media.update_media(media.id, %{
               title: result.title,
               alt: result.alt,
               caption: result.caption
             }) do
          {:ok, _updated} ->
            translate_media_translations(media.id, translate_targets)
            result.title || media.original_name

          {:error, reason} ->
            Logger.warning("Media metadata update failed for #{media.id}: #{inspect(reason)}")
            media.original_name
        end

      {:error, reason} ->
        Logger.warning("AI image analysis skipped for #{media.id}: #{inspect(reason)}")
        media.original_name
    end
  end

  defp translate_media_translations(_media_id, []), do: :ok

  defp translate_media_translations(media_id, [target | rest]) do
    case AI.translate_media(media_id, target) do
      {:ok, translation} ->
        Media.upsert_media_translation(media_id, target, %{
          title: translation.title,
          alt: translation.alt,
          caption: translation.caption
        })

        translate_media_translations(media_id, rest)

      {:error, reason} ->
        Logger.warning(
          "Media translation failed for #{media_id} -> #{target}: #{inspect(reason)}"
        )

        translate_media_translations(media_id, rest)
    end
  end
end
