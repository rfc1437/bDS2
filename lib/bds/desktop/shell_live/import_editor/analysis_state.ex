defmodule BDS.Desktop.ShellLive.ImportEditor.AnalysisState do
  @moduledoc false

  alias BDS.{ImportAnalysis, ImportDefinitions, Metadata}
  alias BDS.Desktop.{FilePicker, FolderPicker, ShellData}

  @spec change_definition(term(), term(), term()) :: term()
  def change_definition(socket, params, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         {:ok, _definition} <-
           ImportDefinitions.update_definition(definition_id, %{name: Map.get(params, "name", "")}) do
      reload.(socket, socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  @spec select_uploads_folder(term(), term(), term()) :: term()
  def select_uploads_folder(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      case FolderPicker.choose_directory(translated("importAnalysis.uploadsFolder")) do
        {:ok, uploads_folder_path} ->
          {:ok, _definition} =
            ImportDefinitions.update_definition(definition_id, %{
              uploads_folder_path: uploads_folder_path
            })

          reload.(socket, socket.assigns.workbench)

        :cancel ->
          reload.(socket, socket.assigns.workbench)

        {:error, %{message: message}} ->
          socket
          |> append_output.(translated("activity.import"), message, nil, "error")
          |> reload.(socket.assigns.workbench)
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  @spec select_and_analyze(term(), term(), term()) :: term()
  def select_and_analyze(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id) do
      case FilePicker.choose_file(translated("importAnalysis.wxrFile")) do
        {:ok, wxr_file_path} ->
          project_id = socket.assigns.projects.active_project_id

          {:ok, _definition} =
            ImportDefinitions.update_definition(definition_id, %{
              wxr_file_path: wxr_file_path,
              last_analysis_result: nil
            })

          live_view_pid = self()

          task =
            Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
              ImportAnalysis.analyze_wxr(
                project_id,
                wxr_file_path,
                definition.uploads_folder_path,
                on_progress: fn step, detail ->
                  send(
                    live_view_pid,
                    {:import_analysis_progress, definition_id, translate_phase(step), detail}
                  )
                end
              )
            end)

          :ok = allow_repo_sandbox(task.pid)

          socket
          |> Phoenix.Component.assign(
            :import_editor_analysis_states,
            Map.put(socket.assigns.import_editor_analysis_states, definition_id, %{
              loading: true,
              step: translated("importAnalysis.analyzingWxr"),
              detail: Path.basename(wxr_file_path),
              file_path: wxr_file_path,
              ref: task.ref
            })
          )
          |> Phoenix.Component.assign(
            :import_editor_analysis_task_refs,
            Map.put(socket.assigns.import_editor_analysis_task_refs, task.ref, definition_id)
          )
          |> Phoenix.Component.assign(
            :import_editor_execution_states,
            Map.delete(socket.assigns.import_editor_execution_states, definition_id)
          )
          |> reload.(socket.assigns.workbench)

        :cancel ->
          reload.(socket, socket.assigns.workbench)

        {:error, %{message: message}} ->
          socket
          |> append_output.(translated("activity.import"), message, nil, "error")
          |> reload.(socket.assigns.workbench)
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  @spec note_analysis_progress(term(), term(), term(), term(), term()) :: term()
  def note_analysis_progress(socket, definition_id, step, detail, reload) do
    socket
    |> Phoenix.Component.assign(
      :import_editor_analysis_states,
      Map.update(
        socket.assigns.import_editor_analysis_states,
        definition_id,
        default_analysis_state(),
        fn state ->
          state
          |> Map.put(:loading, true)
          |> Map.put(:step, step)
          |> Map.put(:detail, detail)
        end
      )
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec finish_analysis(term(), term(), term(), term(), term()) :: term()
  def finish_analysis(socket, ref, result, reload, append_output) do
    case Map.get(socket.assigns.import_editor_analysis_task_refs, ref) do
      nil ->
        socket

      definition_id ->
        analysis_state =
          Map.get(
            socket.assigns.import_editor_analysis_states,
            definition_id,
            default_analysis_state()
          )

        socket =
          socket
          |> Phoenix.Component.assign(
            :import_editor_analysis_task_refs,
            Map.delete(socket.assigns.import_editor_analysis_task_refs, ref)
          )
          |> Phoenix.Component.assign(
            :import_editor_analysis_states,
            Map.delete(socket.assigns.import_editor_analysis_states, definition_id)
          )

        case result do
          {:ok, report} ->
            attrs =
              %{
                wxr_file_path: analysis_state.file_path,
                last_analysis_result: report
              }
              |> maybe_put(:name, suggested_definition_name(report))

            case ImportDefinitions.update_definition(definition_id, attrs) do
              {:ok, _definition} ->
                reload.(socket, socket.assigns.workbench)

              {:error, reason} ->
                socket
                |> append_output.(translated("activity.import"), inspect(reason), nil, "error")
                |> reload.(socket.assigns.workbench)
            end

          {:error, %{message: message}} ->
            socket
            |> append_output.(translated("activity.import"), message, nil, "error")
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("activity.import"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec handle_analysis_task_down(term(), term(), term(), term(), term()) :: term()
  def handle_analysis_task_down(socket, ref, message, reload, append_output) do
    case Map.get(socket.assigns.import_editor_analysis_task_refs, ref) do
      nil ->
        socket

      definition_id ->
        socket
        |> Phoenix.Component.assign(
          :import_editor_analysis_task_refs,
          Map.delete(socket.assigns.import_editor_analysis_task_refs, ref)
        )
        |> Phoenix.Component.assign(
          :import_editor_analysis_states,
          Map.delete(socket.assigns.import_editor_analysis_states, definition_id)
        )
        |> append_output.(translated("activity.import"), message, nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec importable_counts(term()) :: term()
  def importable_counts(nil), do: %{total: 0, tags: 0, posts: 0, media: 0, pages: 0}

  def importable_counts(report) do
    tag_count =
      (Map.get(report.items, :categories, []) ++ Map.get(report.items, :tags, []))
      |> Enum.count(&(not &1.exists_in_project and not present?(&1.mapped_to)))

    posts = importable_entity_count(Map.get(report.items, :posts, []))
    pages = importable_entity_count(Map.get(report.items, :pages, []))
    media = importable_entity_count(Map.get(report.items, :media, []))

    %{
      total: tag_count + posts + pages + media,
      tags: tag_count,
      posts: posts,
      media: media,
      pages: pages
    }
  end

  @spec importable_entity_count(term()) :: term()
  def importable_entity_count(items) do
    Enum.count(items || [], fn item ->
      item.status == "new" or
        (item.status == "conflict" and conflict_importable?(Map.get(item, :resolution, "ignore")))
    end)
  end

  defp conflict_importable?(resolution), do: resolution in ["overwrite", "merge", "import"]

  @spec detail_items(term(), term()) :: term()
  def detail_items(nil, _bucket), do: []

  def detail_items(report, bucket) do
    get_in(report, [:details, bucket]) || get_in(report, [:items, bucket]) || []
  end

  @spec default_analysis_state() :: term()
  def default_analysis_state do
    %{loading: false, step: nil, detail: nil, file_path: nil, ref: nil}
  end

  @spec default_sections() :: term()
  def default_sections do
    %{
      post_conflicts: true,
      page_conflicts: true,
      posts: false,
      other: false,
      pages: false,
      media: false,
      taxonomy: true,
      macros: true
    }
  end

  @spec default_author(term()) :: term()
  def default_author(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    Map.get(metadata, :default_author)
  end

  @spec suggested_definition_name(term()) :: term()
  def suggested_definition_name(report) do
    get_in(report, [:site_info, :url]) || get_in(report, [:site_info, :title])
  end

  @spec maybe_put(term(), term(), term()) :: term()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec allow_repo_sandbox(term()) :: term()
  def allow_repo_sandbox(pid) when is_pid(pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), pid)
      rescue
        _error -> :ok
      end
    else
      :ok
    end

    :ok
  end

  def translate_phase(step) when is_binary(step) do
    case step do
      "parsing" -> translated("importAnalysis.analysisPhase.parsing")
      "scanning" -> translated("importAnalysis.analysisPhase.scanning")
      "taxonomies" -> translated("importAnalysis.analysisPhase.taxonomies")
      "posts" -> translated("importAnalysis.analysisPhase.posts")
      "media" -> translated("importAnalysis.analysisPhase.media")
      "complete" -> translated("importAnalysis.analysisPhase.complete")
      other -> other
    end
  end

  @spec translate_phase(term()) :: term()
  def translate_phase(other), do: other

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  defp present?(value), do: value not in [nil, ""]
end
