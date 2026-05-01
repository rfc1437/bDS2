defmodule BDS.Desktop.ShellLive.ImportEditor.ProgressTracking do
  @moduledoc false

  alias BDS.{ImportDefinitions, ImportExecution}
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.ImportEditor.AnalysisState

  def execute_import(socket, reload, _append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
      project_id = socket.assigns.projects.active_project_id
      default_author = AnalysisState.default_author(project_id)
      counts = AnalysisState.importable_counts(report)

      if counts.total == 0 do
        reload.(socket, socket.assigns.workbench)
      else
        live_view_pid = self()

        task =
          Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
            ImportExecution.execute_import(project_id, report,
              uploads_folder_path: definition.uploads_folder_path,
              default_author: default_author,
              on_progress: fn phase, current, total, detail ->
                send(live_view_pid, {:import_execution_progress, definition_id, phase, current, total, detail})
              end
            )
          end)

        progress_phase = translate_execution_phase("posts")

        :ok = AnalysisState.allow_repo_sandbox(task.pid)

        socket
        |> Phoenix.Component.assign(
          :import_editor_execution_states,
          Map.put(socket.assigns.import_editor_execution_states, definition_id, %{
            is_executing: true,
            completed: false,
            error: nil,
            count: counts.total,
            result: nil,
            phase: progress_phase,
            current: 0,
            total: counts.total,
            detail: nil,
            eta: nil,
            ref: task.ref
          })
        )
        |> Phoenix.Component.assign(:import_editor_execution_task_refs, Map.put(socket.assigns.import_editor_execution_task_refs, task.ref, definition_id))
        |> reload.(socket.assigns.workbench)
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def note_execution_progress(socket, definition_id, phase, current, total, detail, reload) do
    {detail_text, eta} = decompose_progress_detail(detail)
    translated_phase = translate_execution_phase(phase)

    socket
    |> Phoenix.Component.assign(
      :import_editor_execution_states,
      Map.update(socket.assigns.import_editor_execution_states, definition_id, default_execution_state(), fn state ->
        state
        |> Map.put(:is_executing, true)
        |> Map.put(:phase, translated_phase)
        |> Map.put(:current, current)
        |> Map.put(:total, total)
        |> Map.put(:detail, detail_text)
        |> Map.put(:eta, eta)
      end)
    )
    |> reload.(socket.assigns.workbench)
  end

  def finish_execution(socket, ref, result, reload, append_output) do
    case Map.get(socket.assigns.import_editor_execution_task_refs, ref) do
      nil ->
        socket

      definition_id ->
        previous_state = Map.get(socket.assigns.import_editor_execution_states, definition_id, default_execution_state())

        socket =
          socket
          |> Phoenix.Component.assign(:import_editor_execution_task_refs, Map.delete(socket.assigns.import_editor_execution_task_refs, ref))

        case result do
          {:ok, execution_result} ->
            socket
            |> Phoenix.Component.assign(
              :import_editor_execution_states,
              Map.put(socket.assigns.import_editor_execution_states, definition_id, %{
                previous_state
                | is_executing: false,
                  completed: true,
                  error: nil,
                  current: previous_state.total,
                  detail: nil,
                  result: execution_result,
                  ref: nil
              })
            )
            |> append_output.(translated("activity.import"), translated("importAnalysis.importComplete", %{count: previous_state.count}), nil, "info")
            |> reload.(socket.assigns.workbench)

          {:error, %{message: message}} ->
            socket
            |> Phoenix.Component.assign(
              :import_editor_execution_states,
              Map.put(socket.assigns.import_editor_execution_states, definition_id, %{
                previous_state
                | is_executing: false,
                  completed: false,
                  error: message,
                  ref: nil
              })
            )
            |> append_output.(translated("activity.import"), message, nil, "error")
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            message = inspect(reason)

            socket
            |> Phoenix.Component.assign(
              :import_editor_execution_states,
              Map.put(socket.assigns.import_editor_execution_states, definition_id, %{
                previous_state
                | is_executing: false,
                  completed: false,
                  error: message,
                  ref: nil
              })
            )
            |> append_output.(translated("activity.import"), message, nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def handle_task_down(socket, kind, ref, reason, reload, append_output) when reason not in [:normal, :shutdown] do
    message = inspect(reason)

    case kind do
      :analysis ->
        AnalysisState.handle_analysis_task_down(socket, ref, message, reload, append_output)

      :execution ->
        case Map.get(socket.assigns.import_editor_execution_task_refs, ref) do
          nil ->
            socket

          definition_id ->
            previous_state = Map.get(socket.assigns.import_editor_execution_states, definition_id, default_execution_state())

            socket
            |> Phoenix.Component.assign(:import_editor_execution_task_refs, Map.delete(socket.assigns.import_editor_execution_task_refs, ref))
            |> Phoenix.Component.assign(
              :import_editor_execution_states,
              Map.put(socket.assigns.import_editor_execution_states, definition_id, %{
                previous_state
                | is_executing: false,
                  completed: false,
                  error: message,
                  ref: nil
              })
            )
            |> append_output.(translated("activity.import"), message, nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def handle_task_down(socket, _kind, _ref, _reason, _reload, _append_output), do: socket

  def default_execution_state do
    %{
      is_executing: false,
      completed: false,
      error: nil,
      count: 0,
      result: nil,
      phase: nil,
      current: 0,
      total: 0,
      detail: nil,
      eta: nil,
      ref: nil
    }
  end

  def execution_progress_width(state) do
    current = Map.get(state, :current, 0)
    total = Map.get(state, :total, 0)

    cond do
      total <= 0 -> 0
      true -> min(current / total * 100, 100)
    end
  end

  def decompose_progress_detail(%{detail: detail, eta: eta}), do: {to_string_or_nil(detail), eta}
  def decompose_progress_detail(detail) when is_binary(detail) or is_nil(detail), do: {detail, nil}
  def decompose_progress_detail(detail), do: {to_string_or_nil(detail), nil}

  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(value) when is_binary(value), do: value
  def to_string_or_nil(value), do: inspect(value)

  def format_eta(nil), do: nil

  def format_eta(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1000)

    if seconds < 60 do
      translated("importAnalysis.eta", %{value: translated("importAnalysis.etaSeconds", %{count: seconds})})
    else
      m = div(seconds, 60)
      s = rem(seconds, 60)
      translated("importAnalysis.eta", %{value: translated("importAnalysis.etaMinutes", %{minutes: m, seconds: s})})
    end
  end

  def format_eta(_other), do: nil

  def translate_execution_phase(phase) when is_binary(phase) do
    case phase do
      "tags" -> translated("importAnalysis.phase.tags")
      "posts" -> translated("importAnalysis.phase.posts")
      "media" -> translated("importAnalysis.phase.media")
      "pages" -> translated("importAnalysis.phase.pages")
      "complete" -> translated("importAnalysis.phase.complete")
      other -> other
    end
  end

  def translate_execution_phase(other), do: other

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
