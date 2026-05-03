defmodule BDS.Desktop.ShellLive.ImportEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  alias BDS.{AI, ImportAnalysis, ImportDefinitions, ImportExecution}
  alias BDS.Desktop.{FilePicker, FolderPicker, ShellData}

  alias BDS.Desktop.ShellLive.ImportEditor.{
    AnalysisState,
    ConflictResolution,
    ProgressTracking,
    TaxonomyEditing
  }

  import AnalysisState,
    only: [
      default_analysis_state: 0,
      default_sections: 0,
      detail_items: 2,
      importable_counts: 1,
      translate_phase: 1
    ]

  import ProgressTracking,
    only: [
      default_execution_state: 0,
      execution_progress_width: 1,
      format_eta: 1,
      translate_execution_phase: 1
    ]

  import TaxonomyEditing,
    only: [
      existing_taxonomy_terms: 1,
      taxonomy_item_editing?: 3,
      taxonomy_mapping_tooltip: 1,
      taxonomy_pill_class: 1
    ]

  # ── LiveComponent lifecycle ────────────────────────────────────────────────

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :finish_analysis, ref: ref, result: result}, socket) do
    socket =
      case socket.assigns.analysis_state do
        %{ref: ^ref} = _state -> do_finish_analysis(socket, result)
        _other -> socket
      end

    {:ok, build_data(socket)}
  end

  def update(%{action: :finish_execution, ref: ref, result: result}, socket) do
    socket =
      case socket.assigns.execution_state do
        %{ref: ^ref} = _state -> do_finish_execution(socket, result)
        _other -> socket
      end

    {:ok, build_data(socket)}
  end

  def update(%{action: :note_analysis_progress, step: step, detail: detail}, socket) do
    socket =
      socket
      |> assign(
        :analysis_state,
        Map.merge(socket.assigns.analysis_state, %{loading: true, step: step, detail: detail})
      )
      |> build_data()

    {:ok, socket}
  end

  def update(
        %{
          action: :note_execution_progress,
          phase: phase,
          current: current,
          total: total,
          detail: detail
        },
        socket
      ) do
    {detail_text, eta} = ProgressTracking.decompose_progress_detail(detail)

    socket =
      socket
      |> assign(
        :execution_state,
        Map.merge(socket.assigns.execution_state, %{
          is_executing: true,
          phase: translate_execution_phase(phase),
          current: current,
          total: total,
          detail: detail_text,
          eta: eta
        })
      )
      |> build_data()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> ensure_state()
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    import_editor = %{
      id: assigns.definition_id,
      definition_name: assigns.definition_name,
      uploads_folder_path: assigns.uploads_folder_path,
      wxr_file_path: assigns.wxr_file_path,
      report: assigns.report,
      taxonomy_terms: assigns.taxonomy_terms,
      taxonomy_edit: assigns.taxonomy_edit,
      analysis_state: assigns.analysis_state,
      execution_state: assigns.execution_state,
      importable_counts: assigns.importable_counts,
      sections: assigns.sections,
      selected_model: assigns.selected_model,
      selected_model_label: assigns.selected_model_label,
      model_selector_open?: assigns.model_selector_open?,
      available_models: assigns.available_models,
      offline?: assigns.offline_mode?,
      is_loading: assigns.analysis_state.loading
    }

    assigns = Map.put(assigns, :import_editor, import_editor)
    import_editor(assigns)
  end

  # ── Event handlers ─────────────────────────────────────────────────────────

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_import_editor_definition", %{"import_definition" => params}, socket) do
    definition_id = socket.assigns.definition_id

    socket =
      case ImportDefinitions.update_definition(definition_id, %{name: Map.get(params, "name", "")}) do
        {:ok, _definition} -> build_data(socket)
        _other -> build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event("select_import_uploads_folder", _params, socket) do
    definition_id = socket.assigns.definition_id

    socket =
      case FolderPicker.choose_directory(translated("importAnalysis.uploadsFolder")) do
        {:ok, uploads_folder_path} ->
          {:ok, _definition} =
            ImportDefinitions.update_definition(definition_id, %{
              uploads_folder_path: uploads_folder_path
            })

          build_data(socket)

        :cancel ->
          build_data(socket)

        {:error, %{message: message}} ->
          notify_output(translated("activity.import"), message, "error")
          build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event("select_import_wxr_file", _params, socket) do
    definition_id = socket.assigns.definition_id
    project_id = socket.assigns.project_id

    socket =
      case FilePicker.choose_file(translated("importAnalysis.wxrFile")) do
        {:ok, wxr_file_path} ->
          {:ok, definition} =
            ImportDefinitions.update_definition(definition_id, %{
              wxr_file_path: wxr_file_path,
              last_analysis_result: nil
            })

          parent = self()

          task =
            Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
              ImportAnalysis.analyze_wxr(
                project_id,
                wxr_file_path,
                definition.uploads_folder_path,
                on_progress: fn step, detail ->
                  send(parent, {:import_analysis_progress, translate_phase(step), detail})
                end
              )
            end)

          :ok = allow_repo_sandbox(task.pid)

          socket
          |> assign(:analysis_state, %{
            loading: true,
            step: translated("importAnalysis.analyzingWxr"),
            detail: Path.basename(wxr_file_path),
            file_path: wxr_file_path,
            ref: task.ref
          })
          |> assign(:execution_state, default_execution_state())
          |> build_data()

        :cancel ->
          build_data(socket)

        {:error, %{message: message}} ->
          notify_output(translated("activity.import"), message, "error")
          build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event("execute_import_editor", _params, socket) do
    definition_id = socket.assigns.definition_id
    project_id = socket.assigns.project_id

    socket =
      with %{} = definition <- ImportDefinitions.get_definition(definition_id),
           %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
        default_author = AnalysisState.default_author(project_id)
        counts = importable_counts(report)

        if counts.total == 0 do
          build_data(socket)
        else
          parent = self()

          task =
            Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
              ImportExecution.execute_import(project_id, report,
                uploads_folder_path: definition.uploads_folder_path,
                default_author: default_author,
                on_progress: fn phase, current, total, detail ->
                  send(
                    parent,
                    {:import_execution_progress, phase, current, total, detail}
                  )
                end
              )
            end)

          :ok = AnalysisState.allow_repo_sandbox(task.pid)

          progress_phase = translate_execution_phase("posts")

          socket
          |> assign(:execution_state, %{
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
          |> build_data()
        end
      else
        _other -> build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event("change_import_conflict_resolution", params, socket) do
    definition_id = socket.assigns.definition_id

    socket =
      with %{} = definition <- ImportDefinitions.get_definition(definition_id),
           %{} = report <- ImportDefinitions.decode_analysis_result(definition),
           updated_report <-
             ConflictResolution.update_conflict_resolution(
               report,
               Map.get(params, "item_type"),
               Map.get(params, "item_name"),
               Map.get(params, "resolution")
             ),
           {:ok, _definition} <-
             ImportDefinitions.update_definition(definition_id, %{
               last_analysis_result: updated_report
             }) do
        build_data(socket)
      else
        _other -> build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event(
        "start_import_taxonomy_edit",
        %{"type" => type, "name" => name, "mapped_to" => mapped_to},
        socket
      ) do
    socket =
      socket
      |> assign(:taxonomy_edit, %{
        type: type,
        name: name,
        value: mapped_to |> to_string() |> blank_to_nil()
      })
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("save_import_taxonomy_edit", params, socket) do
    definition_id = socket.assigns.definition_id
    project_id = socket.assigns.project_id

    socket =
      with %{} = definition <- ImportDefinitions.get_definition(definition_id),
           %{} = report <- ImportDefinitions.decode_analysis_result(definition),
           type <- Map.get(params, "type"),
           name <- Map.get(params, "name"),
           mapped_to <- Map.get(params, "mapped_to"),
           normalized_value <-
             TaxonomyEditing.normalize_taxonomy_mapping_value(project_id, type, mapped_to),
           updated_report <- TaxonomyEditing.update_taxonomy_mapping(report, type, name, normalized_value),
           {:ok, _definition} <-
             ImportDefinitions.update_definition(definition_id, %{
               last_analysis_result: updated_report
             }) do
        socket
        |> assign(:taxonomy_edit, nil)
        |> build_data()
      else
        _other ->
          socket
          |> assign(:taxonomy_edit, nil)
          |> build_data()
      end

    {:noreply, socket}
  end

  def handle_event("cancel_import_taxonomy_edit", _params, socket) do
    {:noreply, assign(socket, :taxonomy_edit, nil) |> build_data()}
  end

  def handle_event("clear_import_taxonomy_mapping", %{"type" => type, "name" => name}, socket) do
    definition_id = socket.assigns.definition_id
    project_id = socket.assigns.project_id

    socket =
      with %{} = definition <- ImportDefinitions.get_definition(definition_id),
           %{} = report <- ImportDefinitions.decode_analysis_result(definition),
           normalized_value <-
             TaxonomyEditing.normalize_taxonomy_mapping_value(project_id, type, ""),
           updated_report <- TaxonomyEditing.update_taxonomy_mapping(report, type, name, normalized_value),
           {:ok, _definition} <-
             ImportDefinitions.update_definition(definition_id, %{
               last_analysis_result: updated_report
             }) do
        socket
        |> assign(:taxonomy_edit, nil)
        |> build_data()
      else
        _other ->
          socket
          |> assign(:taxonomy_edit, nil)
          |> build_data()
      end

    {:noreply, socket}
  end

  def handle_event("toggle_import_section", %{"section" => section}, socket) do
    section_atom = BDS.BoundedAtoms.import_section(section)

    socket =
      if section_atom do
        next_sections = Map.update!(socket.assigns.sections, section_atom, &(!&1))
        assign(socket, :sections, next_sections) |> build_data()
      else
        build_data(socket)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_import_ai_model_selector", _params, socket) do
    {:noreply,
     assign(socket, :model_selector_open?, not socket.assigns.model_selector_open?) |> build_data()}
  end

  def handle_event("select_import_ai_model", %{"model" => model_id}, socket) do
    socket =
      socket
      |> assign(:selected_model, model_id)
      |> assign(:model_selector_open?, false)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("analyze_import_taxonomy_ai", _params, socket) do
    definition_id = socket.assigns.definition_id
    project_id = socket.assigns.project_id

    socket =
      with %{} = definition <- ImportDefinitions.get_definition(definition_id),
           %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
        if socket.assigns.offline_mode? do
          notify_output(
            translated("activity.import"),
            ShellData.translate(
              "Automatic AI actions stay gated by airplane mode.",
              %{},
              socket.assigns[:page_language] || ShellData.ui_language()
            ),
            "info"
          )

          build_data(socket)
        else
          taxonomy_terms = existing_taxonomy_terms(project_id)

          import_terms = %{
            categories: Enum.map(Map.get(report.items, :categories, []), & &1.name),
            tags: Enum.map(Map.get(report.items, :tags, []), & &1.name)
          }

          opts =
            if socket.assigns.selected_model do
              [model: socket.assigns.selected_model]
            else
              []
            end

          case AI.analyze_import_taxonomy(import_terms, taxonomy_terms, opts) do
            {:ok, analysis} ->
              updated_report = TaxonomyEditing.apply_taxonomy_mappings(report, analysis)

              {:ok, _definition} =
                ImportDefinitions.update_definition(definition_id, %{
                  last_analysis_result: updated_report
                })

              mapped_count = TaxonomyEditing.auto_mapped_count(report, updated_report)

              notify_output(
                translated("activity.import"),
                translated("importAnalysis.mappedCount", %{count: mapped_count}),
                "info"
              )

              build_data(socket)

            {:error, reason} ->
              notify_output(translated("activity.import"), inspect(reason), "error")
              build_data(socket)
          end
        end
      else
        _other -> build_data(socket)
      end

    {:noreply, socket}
  end

  # ── handle_info for async tasks ────────────────────────────────────────────

  @spec handle_info({:import_analysis_progress, atom() | String.t(), String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:import_analysis_progress, step, detail}, socket) do
    socket =
      socket
      |> assign(
        :analysis_state,
        Map.merge(socket.assigns.analysis_state, %{loading: true, step: step, detail: detail})
      )
      |> build_data()

    {:noreply, socket}
  end

  def handle_info(
        {:import_execution_progress, phase, current, total, detail},
        socket
      ) do
    {detail_text, eta} = ProgressTracking.decompose_progress_detail(detail)

    socket =
      socket
      |> assign(
        :execution_state,
        Map.merge(socket.assigns.execution_state, %{
          is_executing: true,
          phase: translate_execution_phase(phase),
          current: current,
          total: total,
          detail: detail_text,
          eta: eta
        })
      )
      |> build_data()

    {:noreply, socket}
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      cond do
        match?(%{ref: ^ref}, socket.assigns.analysis_state) ->
          do_finish_analysis(socket, result)

        match?(%{ref: ^ref}, socket.assigns.execution_state) ->
          do_finish_execution(socket, result)

        true ->
          socket
      end

    {:noreply, build_data(socket)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    socket =
      cond do
        match?(%{ref: ^ref}, socket.assigns.analysis_state) and reason not in [:normal, :shutdown] ->
          message = if is_binary(reason), do: reason, else: inspect(reason)

          socket
          |> assign(:analysis_state, default_analysis_state())
          |> notify_output(translated("activity.import"), message, "error")

        match?(%{ref: ^ref}, socket.assigns.execution_state) and reason not in [:normal, :shutdown] ->
          message = if is_binary(reason), do: reason, else: inspect(reason)

          socket
          |> assign(
            :execution_state,
            Map.merge(socket.assigns.execution_state, %{
              is_executing: false,
              completed: false,
              error: message,
              ref: nil
            })
          )
          |> notify_output(translated("activity.import"), message, "error")

        true ->
          socket
      end

    {:noreply, build_data(socket)}
  end

  # ── State helpers ──────────────────────────────────────────────────────────

  defp ensure_state(socket) do
    definition_id = socket.assigns.current_tab.id

    defaults = %{
      definition_id: definition_id,
      analysis_state: default_analysis_state(),
      execution_state: default_execution_state(),
      sections: default_sections(),
      taxonomy_edit: nil,
      model_selector_open?: false,
      selected_model: nil,
      project_id: socket.assigns[:project_id],
      offline_mode?: socket.assigns[:offline_mode] || true
    }

    Enum.reduce(defaults, socket, fn {key, default}, acc ->
      if is_nil(Map.get(acc.assigns, key)) do
        assign(acc, key, default)
      else
        acc
      end
    end)
  end

  defp build_data(socket) do
    definition_id = socket.assigns.definition_id

    case ImportDefinitions.get_definition(definition_id) do
      nil ->
        assign(socket, :report, nil)

      definition ->
        report = ImportDefinitions.decode_analysis_result(definition)
        taxonomy_terms = existing_taxonomy_terms(socket.assigns.project_id)
        selected_model = resolve_selected_model(socket)
        available_models = AI.available_chat_models(selected_model)

        socket
        |> assign(:definition_name, definition.name)
        |> assign(:uploads_folder_path, definition.uploads_folder_path)
        |> assign(:wxr_file_path, definition.wxr_file_path)
        |> assign(:report, report)
        |> assign(:taxonomy_terms, taxonomy_terms)
        |> assign(:importable_counts, importable_counts(report))
        |> assign(:selected_model, selected_model)
        |> assign(:selected_model_label, selected_model_label(selected_model, available_models))
        |> assign(:available_models, available_models)
        |> maybe_update_tab_meta(definition.name)
    end
  end

  defp maybe_update_tab_meta(socket, name) do
    title = name || translated("importAnalysis.untitledImport")

    notify_parent(
      {:import_editor_tab_meta, socket.assigns.definition_id, title,
       translated("importAnalysis.headerDescription")}
    )

    socket
  end

  defp resolve_selected_model(socket) do
    socket.assigns.selected_model || preferred_model(socket)
  end

  defp preferred_model(socket) do
    preference_key = if socket.assigns.offline_mode?, do: :airplane_chat, else: :chat

    case AI.get_model_preference(preference_key) do
      {:ok, model} when is_binary(model) and model != "" -> model
      _other -> nil
    end
  end

  defp selected_model_label(nil, []), do: translated("importAnalysis.analyzeWith")
  defp selected_model_label(nil, [model | _rest]), do: model.name || model.id

  defp selected_model_label(model_id, available_models) do
    case Enum.find(available_models, &(&1.id == model_id)) do
      nil -> model_id
      model -> model.name || model.id
    end
  end

  # ── Task finishers ─────────────────────────────────────────────────────────

  defp do_finish_analysis(socket, result) do
    analysis_state = socket.assigns.analysis_state
    definition_id = socket.assigns.definition_id

    socket = assign(socket, :analysis_state, default_analysis_state())

    case result do
      {:ok, report} ->
        attrs =
          %{
            wxr_file_path: analysis_state.file_path,
            last_analysis_result: report
          }
          |> maybe_put(:name, AnalysisState.suggested_definition_name(report))

        case ImportDefinitions.update_definition(definition_id, attrs) do
          {:ok, _definition} ->
            socket

          {:error, reason} ->
            notify_output(socket, translated("activity.import"), inspect(reason), "error")
        end

      {:error, %{message: message}} ->
        notify_output(socket, translated("activity.import"), message, "error")

      {:error, reason} ->
        notify_output(socket, translated("activity.import"), inspect(reason), "error")
    end
  end

  defp do_finish_execution(socket, result) do
    previous_state = socket.assigns.execution_state

    socket =
      case result do
        {:ok, _execution_result} ->
          socket
          |> assign(:execution_state, %{
            previous_state
            | is_executing: false,
              completed: true,
              error: nil,
              current: previous_state.total,
              detail: nil,
              ref: nil
          })
          |> notify_output(
            translated("activity.import"),
            translated("importAnalysis.importComplete", %{count: previous_state.count}),
            "info"
          )

        {:error, %{message: message}} ->
          socket
          |> assign(:execution_state, %{
            previous_state
            | is_executing: false,
              completed: false,
              error: message,
              ref: nil
          })
          |> notify_output(translated("activity.import"), message, "error")

        {:error, reason} ->
          message = inspect(reason)

          socket
          |> assign(:execution_state, %{
            previous_state
            | is_executing: false,
              completed: false,
              error: message,
              ref: nil
          })
          |> notify_output(translated("activity.import"), message, "error")
      end

    # Allow DB connections to settle before rebuilding
    Process.sleep(20)
    socket
  end

  # ── Rendering (existing function components) ───────────────────────────────

  attr(:import_editor, :map, required: true)

  @spec import_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def import_editor(assigns) do
    assigns =
      assigns
      |> assign(:report, Map.get(assigns.import_editor, :report))
      |> assign(
        :analysis_state,
        Map.get(assigns.import_editor, :analysis_state, default_analysis_state())
      )
      |> assign(:execution_state, Map.get(assigns.import_editor, :execution_state))
      |> assign(
        :counts,
        Map.get(assigns.import_editor, :importable_counts, %{
          total: 0,
          tags: 0,
          posts: 0,
          media: 0,
          pages: 0
        })
      )
      |> assign(:sections, Map.get(assigns.import_editor, :sections, default_sections()))
      |> assign(:detail_posts, detail_items(Map.get(assigns.import_editor, :report), :posts))
      |> assign(:detail_pages, detail_items(Map.get(assigns.import_editor, :report), :pages))
      |> assign(:detail_media, detail_items(Map.get(assigns.import_editor, :report), :media))
      |> assign(
        :post_conflicts,
        Enum.filter(
          detail_items(Map.get(assigns.import_editor, :report), :posts),
          &(&1.status == "conflict")
        )
      )
      |> assign(
        :page_conflicts,
        Enum.filter(
          detail_items(Map.get(assigns.import_editor, :report), :pages),
          &(&1.status == "conflict")
        )
      )
      |> assign(
        :post_items,
        Enum.filter(
          detail_items(Map.get(assigns.import_editor, :report), :posts),
          &(Map.get(&1, :post_type, "post") == "post")
        )
      )
      |> assign(
        :other_items,
        Enum.reject(
          detail_items(Map.get(assigns.import_editor, :report), :posts),
          &(Map.get(&1, :post_type, "post") == "post")
        )
      )

    ~H"""
    <div class="import-analysis" data-testid="import-editor">
      <form class="import-analysis-header" data-testid="import-editor-form" phx-change="change_import_editor_definition" phx-target={@myself}>
        <input
          class="import-definition-name"
          type="text"
          name="import_definition[name]"
          value={@import_editor.definition_name || translated("importAnalysis.untitledImport")}
          placeholder={translated("importAnalysis.namePlaceholder")}
        />
        <p><%= translated("importAnalysis.headerDescription") %></p>
      </form>

      <div class="import-file-selectors">
        <div class="import-file-row">
          <label><%= translated("importAnalysis.uploadsFolder") %></label>
          <div class={["import-file-path", if(blank?(@import_editor.uploads_folder_path), do: "placeholder")]}>
            <%= @import_editor.uploads_folder_path || translated("importAnalysis.noFolderSelected") %>
          </div>
          <button type="button" phx-click="select_import_uploads_folder" phx-target={@myself}><%= translated("Open") %></button>
        </div>

        <div class="import-file-row">
          <label><%= translated("importAnalysis.wxrFile") %></label>
          <div class={["import-file-path", if(blank?(@import_editor.wxr_file_path), do: "placeholder")]}>
            <%= @import_editor.wxr_file_path || translated("importAnalysis.selectFileToAnalyze") %>
          </div>
          <button class="import-analyze-btn" type="button" phx-click="select_import_wxr_file" phx-target={@myself}><%= translated("importAnalysis.selectAndAnalyze") %></button>
        </div>
      </div>

      <%= if @import_editor.is_loading do %>
        <div class="import-loading">
          <div class="import-spinner"></div>
          <div class="import-progress">
            <div class="import-progress-step"><%= @analysis_state.step || translated("importAnalysis.analyzingWxr") %></div>
            <%= if present?(@analysis_state.detail) do %>
              <div class="import-progress-detail"><%= @analysis_state.detail %></div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if not is_nil(@report) and not @import_editor.is_loading do %>
        <div class="import-site-info">
          <div class="import-site-info-item">
            <span class="info-label"><%= translated("importAnalysis.site") %></span>
            <span class="info-value"><%= get_in(@report, [:site_info, :title]) || translated("importAnalysis.untitled") %></span>
          </div>
          <div class="import-site-info-item">
            <span class="info-label"><%= translated("importAnalysis.url") %></span>
            <span class="info-value"><%= get_in(@report, [:site_info, :url]) || translated("importAnalysis.notAvailable") %></span>
          </div>
          <div class="import-site-info-item">
            <span class="info-label"><%= translated("importAnalysis.language") %></span>
            <span class="info-value"><%= get_in(@report, [:site_info, :language]) || translated("importAnalysis.notAvailable") %></span>
          </div>
          <div class="import-site-info-item">
            <span class="info-label"><%= translated("importAnalysis.file") %></span>
            <span class="info-value"><%= @import_editor.wxr_file_path |> to_string() |> Path.basename() %></span>
          </div>
        </div>

        <div class="import-stat-cards">
          <.stat_card label={translated("importAnalysis.posts")} stats={@report.post_stats} />
          <%= if Map.get(@report, :other_stats) && Map.get(@report.other_stats, :total, 0) > 0 do %>
            <.other_stat_card label={translated("importAnalysis.other")} stats={@report.other_stats} />
          <% end %>
          <.stat_card label={translated("importAnalysis.pages")} stats={@report.page_stats} />
          <.media_stat_card label={translated("importAnalysis.media")} stats={@report.media_stats} />
          <.taxonomy_stat_card label={translated("importAnalysis.categories")} stats={@report.category_stats} />
          <.taxonomy_stat_card label={translated("importAnalysis.tags")} stats={@report.tag_stats} />
        </div>

        <%= if Enum.any?(Map.get(@report, :date_distribution, [])) do %>
          <div class="import-date-distribution">
            <h3><%= translated("importAnalysis.dateDistribution") %></h3>
            <div class="distribution-bars">
              <%= for row <- @report.date_distribution do %>
                <div class="distribution-row">
                  <span class="distribution-year"><%= row.year %></span>
                  <div class="distribution-bar-container">
                    <div class="distribution-bar distribution-bar-posts" style={"width: #{distribution_width(row.post_count, @report.date_distribution, :post_count)}%;"}></div>
                    <div class="distribution-bar distribution-bar-media" style={"width: #{distribution_width(row.media_count, @report.date_distribution, :media_count)}%;"}></div>
                  </div>
                  <span class="distribution-count"><%= row.post_count %> / <%= row.media_count %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @execution_state.is_executing do %>
          <div class="import-execution-progress">
            <div class="import-execution-header">
              <h3><%= translated("importAnalysis.importing") %></h3>
            </div>
            <div class="import-progress-bar">
              <div class="import-progress-fill" style={"width: #{execution_progress_width(@execution_state)}%;"}></div>
            </div>
            <div class="import-progress-info">
              <span class="import-phase"><%= @execution_state.phase || translated("importAnalysis.executionStarting") %></span>
              <%= if present?(@execution_state.detail) do %>
                <span class="import-detail"><%= @execution_state.detail %></span>
              <% end %>
              <span class="import-counter"><%= @execution_state.current || 0 %> / <%= @execution_state.total || @counts.total %></span>
              <%= if eta = format_eta(Map.get(@execution_state, :eta)) do %>
                <span class="import-eta"><%= eta %></span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if not @execution_state.is_executing and not @execution_state.completed do %>
          <div class="import-execute-section">
            <div class="import-execute-summary">
              <%= translated("importAnalysis.readyToImport") %>
              <%= if @counts.tags > 0 do %><span class="import-count-tag"><%= @counts.tags %> <%= translated("importAnalysis.tagsCategories") %></span><% end %>
              <%= if @counts.posts > 0 do %><span class="import-count-tag"><%= @counts.posts %> <%= translated("importAnalysis.posts") %></span><% end %>
              <%= if @counts.media > 0 do %><span class="import-count-tag"><%= @counts.media %> <%= translated("importAnalysis.media") %></span><% end %>
              <%= if @counts.pages > 0 do %><span class="import-count-tag"><%= @counts.pages %> <%= translated("importAnalysis.pages") %></span><% end %>
            </div>

            <button class="import-execute-btn" type="button" phx-click="execute_import_editor" phx-target={@myself} disabled={@counts.total == 0}>
              <%= if @counts.total == 0 do %>
                <%= translated("importAnalysis.nothingToImport") %>
              <% else %>
                <%= translated("importAnalysis.importItems", %{count: @counts.total}) %>
              <% end %>
            </button>
          </div>
        <% end %>

        <%= if @execution_state.completed do %>
          <div class="import-execution-complete">
            <span><%= translated("importAnalysis.importComplete", %{count: @execution_state.count || @counts.total}) %></span>
          </div>
        <% end %>

        <%= if present?(@execution_state.error) do %>
          <div class="import-execution-error">
            <span><%= translated("importAnalysis.importFailed", %{error: @execution_state.error}) %></span>
          </div>
        <% end %>

        <%= if Enum.any?(@post_conflicts) do %>
          <.conflict_section title={translated("importAnalysis.postSlugConflicts")} items={@post_conflicts} expanded={@sections.post_conflicts} section="post_conflicts" myself={@myself} />
        <% end %>

        <%= if Enum.any?(@page_conflicts) do %>
          <.conflict_section title={translated("importAnalysis.pageSlugConflicts")} items={@page_conflicts} expanded={@sections.page_conflicts} section="page_conflicts" myself={@myself} />
        <% end %>

        <%= if Enum.any?(@post_items) do %>
          <.post_detail_section title={translated("importAnalysis.postsWithCount", %{count: length(@post_items)})} items={@post_items} expanded={@sections.posts} section="posts" myself={@myself} />
        <% end %>

        <%= if Enum.any?(@other_items) do %>
          <.post_detail_section title={translated("importAnalysis.otherWithCount", %{count: length(@other_items)})} items={@other_items} expanded={@sections.other} section="other" show_type={true} myself={@myself} />
        <% end %>

        <%= if Enum.any?(@detail_pages) do %>
          <.post_detail_section title={translated("importAnalysis.pagesWithCount", %{count: length(@detail_pages)})} items={@detail_pages} expanded={@sections.pages} section="pages" myself={@myself} />
        <% end %>

        <%= if Enum.any?(@detail_media) do %>
          <.media_detail_section title={translated("importAnalysis.mediaWithCount", %{count: length(@detail_media)})} items={@detail_media} expanded={@sections.media} section="media" myself={@myself} />
        <% end %>

        <%= if Enum.any?(Map.get(@report.items, :categories, [])) or Enum.any?(Map.get(@report.items, :tags, [])) do %>
          <section class="import-detail-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-target={@myself} phx-value-section="taxonomy">
              <span><%= translated("importAnalysis.taxonomyTitle") %></span>
              <span class="toggle-icon"><%= if @sections.taxonomy, do: "▾", else: "▸" %></span>
            </button>

            <%= if @sections.taxonomy do %>
              <div class="taxonomy-analyze-row">
                <div class="taxonomy-analyze-dropdown">
                  <button class="taxonomy-analyze-btn" type="button" phx-click="toggle_import_ai_model_selector" phx-target={@myself}><%= translated("importAnalysis.analyzeWith") %></button>
                  <%= if @import_editor.model_selector_open? do %>
                    <div class="taxonomy-model-dropdown">
                      <%= for model <- @import_editor.available_models do %>
                        <button class="taxonomy-model-option" type="button" phx-click="select_import_ai_model" phx-target={@myself} phx-value-model={model.id}>
                          <%= model.provider_name || model.provider || translated("importAnalysis.unknown") %>: <%= model.name || model.id %>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <button class="taxonomy-analyze-btn" type="button" phx-click="analyze_import_taxonomy_ai" phx-target={@myself} disabled={Enum.empty?(@import_editor.available_models) and not @import_editor.offline?}>
                  <%= @import_editor.selected_model_label %>
                </button>

                <span class="taxonomy-analyze-hint"><%= translated("importAnalysis.aiMappingHint") %></span>
              </div>

              <div class="import-taxonomy-groups">
                <.taxonomy_group
                  title={translated("importAnalysis.categories")}
                  items={Map.get(@report.items, :categories, [])}
                  suggestions={Map.get(@import_editor.taxonomy_terms, :categories, [])}
                  edit={@import_editor.taxonomy_edit}
                  type="categories"
                  myself={@myself}
                />
                <.taxonomy_group
                  title={translated("importAnalysis.tags")}
                  items={Map.get(@report.items, :tags, [])}
                  suggestions={Map.get(@import_editor.taxonomy_terms, :tags, [])}
                  edit={@import_editor.taxonomy_edit}
                  type="tags"
                  myself={@myself}
                />
              </div>
            <% end %>
          </section>
        <% end %>

        <% macros = Map.get(@report, :macros, %{}) %>
        <%= if Enum.any?(Map.get(macros, :discovered, [])) do %>
          <section class="import-detail-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-target={@myself} phx-value-section="macros">
              <span><%= translated("importAnalysis.macrosWithCount", %{count: macros.total || length(macros.discovered)}) %></span>
              <span class="toggle-icon"><%= if @sections.macros, do: "▾", else: "▸" %></span>
            </button>

            <%= if @sections.macros do %>
              <div class="macros-summary">
                <span class="macros-mapped"><%= translated("importAnalysis.mappedCount", %{count: macros.mapped_count || 0}) %></span>
                <span class="macros-unmapped"><%= translated("importAnalysis.unmappedCount", %{count: macros.unmapped_count || 0}) %></span>
              </div>
              <div class="macros-list">
                <%= for macro <- macros.discovered do %>
                  <div class={"macro-item #{if macro.mapped, do: "mapped", else: "unmapped"}"}>
                    <div class="macro-header">
                      <span class="macro-name"><%= macro.name %></span>
                      <span class={"macro-status-badge #{if macro.mapped, do: "mapped", else: "unmapped"}"}>
                        <%= if macro.mapped, do: translated("importAnalysis.macroStatusMapped"), else: translated("importAnalysis.macroStatusUnknown") %>
                      </span>
                      <span class="macro-count"><%= translated("importAnalysis.macroUses", %{count: macro.total_count}) %></span>
                    </div>
                    <%= if Enum.any?(Map.get(macro, :usages, [])) do %>
                      <div class="macro-usages">
                        <%= for usage <- macro.usages do %>
                          <div class="macro-usage">
                            <span class="macro-usage-params">
                              <%= if Enum.any?(Map.get(usage, :params, %{})) do %>
                                <%= for {k, v} <- usage.params do %>
                                  <span class="macro-usage-param"><%= k %>=<%= v %></span>
                                <% end %>
                              <% else %>
                                <%= translated("importAnalysis.noParameters") %>
                              <% end %>
                            </span>
                            <span class="macro-usage-count"><%= translated("importAnalysis.macroUses", %{count: usage.count}) %></span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if Enum.any?(Map.get(macro, :post_slugs, [])) do %>
                      <div class="macro-post-slugs">
                        <%= translated("importAnalysis.usedIn", %{items: Enum.join(Enum.take(macro.post_slugs, 5), ", "), more: if(length(macro.post_slugs) > 5, do: translated("importAnalysis.moreSuffix", %{count: length(macro.post_slugs) - 5}), else: "")}) %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </section>
        <% end %>
      <% else %>
        <%= if @import_editor.is_loading do %>
        <% else %>
        <div class="import-empty-state">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
            <path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"></path>
          </svg>
          <p><%= translated("importAnalysis.emptyState") %></p>
        </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)
  attr(:myself, :any, required: true)

  @spec conflict_section(map()) :: Phoenix.LiveView.Rendered.t()
  def conflict_section(assigns) do
    ~H"""
    <section class="import-detail-section conflicts-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-target={@myself} phx-value-section={@section}>
        <span><%= @title %></span>
        <span class="toggle-icon"><%= if @expanded, do: "▾", else: "▸" %></span>
      </button>

      <%= if @expanded do %>
        <table class="import-detail-table conflicts-table">
          <thead>
            <tr>
              <th><%= translated("importAnalysis.slug") %></th>
              <th><%= translated("importAnalysis.newEntryWxr") %></th>
              <th><%= translated("importAnalysis.existingEntry") %></th>
              <th><%= translated("importAnalysis.resolution") %></th>
            </tr>
          </thead>
          <tbody>
            <%= for item <- @items do %>
              <tr>
                <td class="slug-cell"><%= Map.get(item, :slug) %></td>
                <td><%= Map.get(item, :title) %></td>
                <td><%= Map.get(item, :existing_title) || translated("importAnalysis.none") %></td>
                <td>
                  <form phx-change="change_import_conflict_resolution" phx-target={@myself}>
                    <input type="hidden" name="item_type" value={Map.get(item, :item_type)} />
                    <input type="hidden" name="item_name" value={Map.get(item, :slug)} />
                    <select class="resolution-select" name="resolution">
                      <option value="ignore" selected={conflict_resolution_selected?(item, "ignore")}><%= translated("importAnalysis.ignore") %></option>
                      <option value="overwrite" selected={conflict_resolution_selected?(item, "overwrite")}><%= translated("importAnalysis.overwrite") %></option>
                      <option value="import" selected={Map.get(item, :resolution) == "import"}><%= translated("importAnalysis.importNewSlug") %></option>
                    </select>
                  </form>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)
  attr(:show_type, :boolean, default: false)
  attr(:myself, :any, required: true)

  @spec post_detail_section(map()) :: Phoenix.LiveView.Rendered.t()
  def post_detail_section(assigns) do
    ~H"""
    <section class="import-detail-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-target={@myself} phx-value-section={@section}>
        <span><%= @title %></span>
        <span class="toggle-icon"><%= if @expanded, do: "▾", else: "▸" %></span>
      </button>

      <%= if @expanded do %>
        <table class="import-detail-table">
          <thead>
            <tr>
              <th><%= translated("importAnalysis.status") %></th>
              <%= if @show_type do %>
                <th><%= translated("importAnalysis.type") %></th>
              <% end %>
              <th><%= translated("importAnalysis.title") %></th>
              <th><%= translated("importAnalysis.slug") %></th>
              <th><%= translated("importAnalysis.categories") %></th>
              <th><%= translated("importAnalysis.wpStatus") %></th>
              <th><%= translated("importAnalysis.existingMatch") %></th>
            </tr>
          </thead>
          <tbody>
            <%= for item <- @items do %>
              <tr>
                <td><span class={status_badge_class(item.status)}><%= item.status %></span></td>
                <%= if @show_type do %>
                  <td class="post-type-cell"><%= Map.get(item, :post_type, Map.get(item, :item_type)) %></td>
                <% end %>
                <td><%= Map.get(item, :title) %></td>
                <td class="slug-cell"><%= Map.get(item, :slug) %></td>
                <td class="categories-cell"><%= joined_or_none(Map.get(item, :categories)) %></td>
                <td><%= Map.get(item, :wp_status) || translated("importAnalysis.none") %></td>
                <td class="existing-match"><%= Map.get(item, :existing_title) || translated("importAnalysis.none") %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)
  attr(:myself, :any, required: true)

  @spec media_detail_section(map()) :: Phoenix.LiveView.Rendered.t()
  def media_detail_section(assigns) do
    ~H"""
    <section class="import-detail-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-target={@myself} phx-value-section={@section}>
        <span><%= @title %></span>
        <span class="toggle-icon"><%= if @expanded, do: "▾", else: "▸" %></span>
      </button>

      <%= if @expanded do %>
        <table class="import-detail-table">
          <thead>
            <tr>
              <th><%= translated("importAnalysis.status") %></th>
              <th><%= translated("importAnalysis.filename") %></th>
              <th><%= translated("importAnalysis.type") %></th>
              <th><%= translated("importAnalysis.path") %></th>
              <th><%= translated("importAnalysis.existingMatch") %></th>
            </tr>
          </thead>
          <tbody>
            <%= for item <- @items do %>
              <tr>
                <td><span class={status_badge_class(item.status)}><%= item.status %></span></td>
                <td><%= Map.get(item, :filename) %></td>
                <td class="mime-type-cell"><%= Map.get(item, :mime_type) || translated("importAnalysis.none") %></td>
                <td class="slug-cell"><%= Map.get(item, :relative_path) %></td>
                <td class="existing-match"><%= Map.get(item, :existing_title) || translated("importAnalysis.none") %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:stats, :map, required: true)

  @spec stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def stat_card(assigns) do
    ~H"""
    <div class="import-stat-card">
      <h3><%= @label %></h3>
      <div class="import-stat-number"><%= total_stats(@stats) %></div>
      <div class="import-stat-breakdown">
        <%= if @stats.new_count > 0 do %><span class="import-stat-tag stat-new"><%= @stats.new_count %> <%= translated("importAnalysis.new") %></span><% end %>
        <%= if @stats.update_count > 0 do %><span class="import-stat-tag stat-update"><%= @stats.update_count %> <%= translated("importAnalysis.update") %></span><% end %>
        <%= if @stats.conflict_count > 0 do %><span class="import-stat-tag stat-conflict"><%= @stats.conflict_count %> <%= translated("importAnalysis.conflict") %></span><% end %>
        <%= if @stats.duplicate_count > 0 do %><span class="import-stat-tag stat-duplicate"><%= @stats.duplicate_count %> <%= translated("importAnalysis.duplicate") %></span><% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:stats, :map, required: true)

  @spec other_stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def other_stat_card(assigns) do
    ~H"""
    <div class="import-stat-card import-stat-card-other">
      <h3><%= @label %></h3>
      <div class="import-stat-number"><%= Map.get(@stats, :total, 0) %></div>
      <div class="import-stat-breakdown">
        <%= for type <- Map.get(@stats, :types, []) do %>
          <span class="import-stat-tag stat-other"><%= type %></span>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:stats, :map, required: true)

  @spec media_stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def media_stat_card(assigns) do
    ~H"""
    <div class="import-stat-card">
      <h3><%= @label %></h3>
      <div class="import-stat-number"><%= total_media_stats(@stats) %></div>
      <div class="import-stat-breakdown">
        <%= if @stats.new_count > 0 do %><span class="import-stat-tag stat-new"><%= @stats.new_count %> <%= translated("importAnalysis.new") %></span><% end %>
        <%= if @stats.update_count > 0 do %><span class="import-stat-tag stat-update"><%= @stats.update_count %> <%= translated("importAnalysis.update") %></span><% end %>
        <%= if @stats.conflict_count > 0 do %><span class="import-stat-tag stat-conflict"><%= @stats.conflict_count %> <%= translated("importAnalysis.conflict") %></span><% end %>
        <%= if @stats.duplicate_count > 0 do %><span class="import-stat-tag stat-duplicate"><%= @stats.duplicate_count %> <%= translated("importAnalysis.duplicate") %></span><% end %>
        <%= if @stats.missing_count > 0 do %><span class="import-stat-tag stat-missing"><%= @stats.missing_count %> <%= translated("importAnalysis.missing") %></span><% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:stats, :map, required: true)

  @spec taxonomy_stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def taxonomy_stat_card(assigns) do
    ~H"""
    <div class="import-stat-card">
      <h3><%= @label %></h3>
      <div class="import-stat-number"><%= @stats.existing_count + @stats.mapped_count + @stats.new_count %></div>
      <div class="import-stat-breakdown">
        <%= if @stats.existing_count > 0 do %><span class="import-stat-tag stat-update"><%= @stats.existing_count %> <%= translated("importAnalysis.existing") %></span><% end %>
        <%= if @stats.mapped_count > 0 do %><span class="import-stat-tag stat-mapped"><%= @stats.mapped_count %> <%= translated("importAnalysis.mapped") %></span><% end %>
        <%= if @stats.new_count > 0 do %><span class="import-stat-tag stat-new"><%= @stats.new_count %> <%= translated("importAnalysis.new") %></span><% end %>
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:suggestions, :list, required: true)
  attr(:edit, :map, default: nil)
  attr(:type, :string, required: true)
  attr(:myself, :any, required: true)

  @spec taxonomy_group(map()) :: Phoenix.LiveView.Rendered.t()
  def taxonomy_group(assigns) do
    ~H"""
    <div class="taxonomy-group">
      <h4><%= @title %></h4>
      <datalist id={"taxonomy-suggestions-#{@type}"}>
        <%= for term <- @suggestions do %>
          <option value={term}></option>
        <% end %>
      </datalist>
      <div class="import-taxonomy-list">
        <%= for item <- @items do %>
          <%= if taxonomy_item_editing?(@edit, @type, item.name) do %>
            <form class="import-taxonomy-edit-form" phx-submit="save_import_taxonomy_edit" phx-target={@myself}>
              <input type="hidden" name="type" value={@type} />
              <input type="hidden" name="name" value={item.name} />
              <span class={taxonomy_pill_class(item)}><%= item.name %></span>
              <input
                class="taxonomy-mapping-input"
                type="text"
                name="mapped_to"
                value={Map.get(@edit || %{}, :value, Map.get(item, :mapped_to) || "") || ""}
                placeholder={translated("importAnalysis.mapToPlaceholder")}
                list={"taxonomy-suggestions-#{@type}"}
                autocomplete="off"
              />
              <button class="taxonomy-edit-btn" type="submit" title={translated("importAnalysis.mapToPlaceholder")}>✓</button>
              <button class="taxonomy-edit-btn ghost" type="button" phx-click="cancel_import_taxonomy_edit" phx-target={@myself} title={translated("Cancel")}>×</button>
              <%= if present?(item.mapped_to) do %>
                <button class="taxonomy-clear-btn" type="button" phx-click="clear_import_taxonomy_mapping" phx-target={@myself} phx-value-type={@type} phx-value-name={item.name} title={translated("importAnalysis.clearMapping")}>×</button>
              <% end %>
            </form>
          <% else %>
            <div class="import-taxonomy-entry">
              <%= if item.exists_in_project do %>
                <span class={taxonomy_pill_class(item)}><%= item.name %></span>
              <% else %>
                <button
                  class={taxonomy_pill_class(item)}
                  type="button"
                  phx-click="start_import_taxonomy_edit"
                  phx-target={@myself}
                  phx-value-type={@type}
                  phx-value-name={item.name}
                  phx-value-mapped_to={Map.get(item, :mapped_to) || ""}
                  title={taxonomy_mapping_tooltip(item)}
                ><%= item.name %></button>
              <% end %>

              <%= if present?(item.mapped_to) do %>
                <span class="taxonomy-mapping-arrow">→</span>
                <button
                  class="import-taxonomy-pill mapped-target"
                  type="button"
                  phx-click="start_import_taxonomy_edit"
                  phx-target={@myself}
                  phx-value-type={@type}
                  phx-value-name={item.name}
                  phx-value-mapped_to={Map.get(item, :mapped_to) || ""}
                ><%= item.mapped_to %></button>
                <button class="taxonomy-clear-btn" type="button" phx-click="clear_import_taxonomy_mapping" phx-target={@myself} phx-value-type={@type} phx-value-name={item.name} title={translated("importAnalysis.clearMapping")}>×</button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp notify_parent(message) do
    send(self(), message)
  end

  defp notify_output(socket, title, message, level \\ "info") do
    notify_parent({:import_editor_output, title, message, level})
    socket
  end

  defp allow_repo_sandbox(pid) when is_pid(pid) do
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

  defp joined_or_none(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp joined_or_none(_values), do: translated("importAnalysis.none")

  defp status_badge_class(status), do: ["status-badge", status]

  defp distribution_width(value, rows, key) do
    max_value = rows |> Enum.map(&Map.get(&1, key, 0)) |> Enum.max(fn -> 1 end)
    max(8, value / max(max_value, 1) * 100)
  end

  defp total_stats(stats),
    do: stats.new_count + stats.update_count + stats.conflict_count + stats.duplicate_count

  defp total_media_stats(stats), do: total_stats(stats) + stats.missing_count

  defp conflict_resolution_selected?(item, "ignore") do
    Map.get(item, :resolution, "ignore") in ["ignore", "skip"]
  end

  defp conflict_resolution_selected?(item, "overwrite") do
    Map.get(item, :resolution) in ["overwrite", "merge"]
  end

  defp present?(value), do: value not in [nil, ""]
  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
