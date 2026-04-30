defmodule BDS.Desktop.ShellLive.ImportEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.{FilePicker, FolderPicker, ShellData}
  alias BDS.{AI, ImportAnalysis, ImportDefinitions, ImportExecution, Metadata, Tags}

  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :import, id: definition_id} ->
        case ImportDefinitions.get_definition(definition_id) do
          nil ->
            assign(socket, :import_editor, nil)

          definition ->
            report = ImportDefinitions.decode_analysis_result(definition)
            taxonomy_terms = existing_taxonomy_terms(socket.assigns.projects.active_project_id)
            analysis_state = Map.get(socket.assigns.import_editor_analysis_states, definition.id, default_analysis_state())
            execution_state = Map.get(socket.assigns.import_editor_execution_states, definition.id, default_execution_state())
            sections = Map.get(socket.assigns.import_editor_sections, definition.id, default_sections())
            selected_model = selected_model(socket.assigns, definition.id)
            available_models = AI.available_chat_models(selected_model)

            import_editor = %{
              definition_id: definition.id,
              definition_name: definition.name,
              uploads_folder_path: definition.uploads_folder_path,
              wxr_file_path: definition.wxr_file_path,
              report: report,
              taxonomy_terms: taxonomy_terms,
              taxonomy_edit: Map.get(socket.assigns.import_editor_taxonomy_edits, definition.id),
              analysis_state: analysis_state,
              execution_state: execution_state,
              importable_counts: importable_counts(report),
              sections: sections,
              selected_model: selected_model,
              selected_model_label: selected_model_label(selected_model, available_models),
              model_selector_open?: Map.get(socket.assigns.import_editor_model_selectors_open, definition.id, false),
              available_models: available_models,
              offline?: Map.get(socket.assigns, :offline_mode, true),
              is_loading: analysis_state.loading
            }

            socket
            |> assign(:import_editor, import_editor)
            |> assign(
              :tab_meta,
              Map.put(socket.assigns.tab_meta, {:import, definition.id}, %{
                title: definition.name || translated("importAnalysis.untitledImport"),
                subtitle: translated("importAnalysis.headerDescription")
              })
            )
        end

      _other ->
        assign(socket, :import_editor, nil)
    end
  end

  def change_definition(socket, params, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{name: Map.get(params, "name", "")}) do
      reload.(socket, socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def select_uploads_folder(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      case FolderPicker.choose_directory(translated("importAnalysis.uploadsFolder")) do
        {:ok, uploads_folder_path} ->
          {:ok, _definition} = ImportDefinitions.update_definition(definition_id, %{uploads_folder_path: uploads_folder_path})
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
              ImportAnalysis.analyze_wxr(project_id, wxr_file_path, definition.uploads_folder_path,
                on_progress: fn step, detail ->
                  send(live_view_pid, {:import_analysis_progress, definition_id, translate_phase(step), detail})
                end
              )
            end)

          :ok = allow_repo_sandbox(task.pid)

          socket
          |> assign(
            :import_editor_analysis_states,
            Map.put(socket.assigns.import_editor_analysis_states, definition_id, %{
              loading: true,
              step: translated("importAnalysis.analyzingWxr"),
              detail: Path.basename(wxr_file_path),
              file_path: wxr_file_path,
              ref: task.ref
            })
          )
          |> assign(:import_editor_analysis_task_refs, Map.put(socket.assigns.import_editor_analysis_task_refs, task.ref, definition_id))
          |> assign(:import_editor_execution_states, Map.delete(socket.assigns.import_editor_execution_states, definition_id))
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

  def execute_import(socket, reload, _append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
      project_id = socket.assigns.projects.active_project_id
      default_author = default_author(project_id)
      counts = importable_counts(report)

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

        :ok = allow_repo_sandbox(task.pid)

        socket
        |> assign(
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
        |> assign(:import_editor_execution_task_refs, Map.put(socket.assigns.import_editor_execution_task_refs, task.ref, definition_id))
        |> reload.(socket.assigns.workbench)
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def change_conflict_resolution(socket, %{"item_type" => item_type, "item_name" => item_name, "resolution" => resolution}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition),
         updated_report <- update_conflict_resolution(report, item_type, item_name, resolution),
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report}) do
      reload.(socket, socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def start_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => mapped_to}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> assign(
        :import_editor_taxonomy_edits,
        Map.put(socket.assigns.import_editor_taxonomy_edits, definition_id, %{
          type: type,
          name: name,
          value: mapped_to |> to_string() |> blank_to_nil()
        })
      )
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def cancel_taxonomy_edit(socket, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> assign(:import_editor_taxonomy_edits, Map.delete(socket.assigns.import_editor_taxonomy_edits, definition_id))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def save_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => mapped_to}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition),
         normalized_value <- normalize_taxonomy_mapping_value(socket.assigns.projects.active_project_id, type, mapped_to),
         updated_report <- update_taxonomy_mapping(report, type, name, normalized_value),
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report}) do
      socket
      |> assign(:import_editor_taxonomy_edits, Map.delete(socket.assigns.import_editor_taxonomy_edits, definition_id))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def clear_taxonomy_mapping(socket, %{"type" => type, "name" => name}, reload) do
    save_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => ""}, reload)
  end

  def toggle_section(socket, section, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         section_key when section_key in ["post_conflicts", "page_conflicts", "posts", "other", "pages", "media", "taxonomy", "macros"] <- section do
      next_sections =
        socket.assigns.import_editor_sections
        |> Map.get(definition_id, default_sections())
        |> Map.update!(String.to_existing_atom(section_key), &(!&1))

      socket
      |> assign(:import_editor_sections, Map.put(socket.assigns.import_editor_sections, definition_id, next_sections))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def toggle_model_selector(socket, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      current = Map.get(socket.assigns.import_editor_model_selectors_open, definition_id, false)

      socket
      |> assign(:import_editor_model_selectors_open, Map.put(socket.assigns.import_editor_model_selectors_open, definition_id, not current))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def select_ai_model(socket, model_id, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> assign(:import_editor_selected_models, Map.put(socket.assigns.import_editor_selected_models, definition_id, model_id))
      |> assign(:import_editor_model_selectors_open, Map.put(socket.assigns.import_editor_model_selectors_open, definition_id, false))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def analyze_taxonomy_ai(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
      cond do
        socket.assigns.offline_mode ->
          socket
          |> append_output.(translated("activity.import"), ShellData.translate("Automatic AI actions stay gated by airplane mode.", %{}, socket.assigns.page_language), nil, "info")
          |> reload.(socket.assigns.workbench)

        true ->
          taxonomy_terms = existing_taxonomy_terms(socket.assigns.projects.active_project_id)

          import_terms = %{
            categories: Enum.map(Map.get(report.items, :categories, []), & &1.name),
            tags: Enum.map(Map.get(report.items, :tags, []), & &1.name)
          }

          opts = maybe_put_option([], :model, Map.get(socket.assigns.import_editor_selected_models, definition_id))

          case AI.analyze_import_taxonomy(import_terms, taxonomy_terms, opts) do
            {:ok, analysis} ->
              updated_report = apply_taxonomy_mappings(report, analysis)
              {:ok, _definition} = ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report})
              mapped_count = auto_mapped_count(report, updated_report)

              socket
              |> append_output.(translated("activity.import"), translated("importAnalysis.mappedCount", %{count: mapped_count}), Map.get(socket.assigns.import_editor_selected_models, definition_id), "info")
              |> reload.(socket.assigns.workbench)

            {:error, reason} ->
              socket
              |> append_output.(translated("activity.import"), inspect(reason), Map.get(socket.assigns.import_editor_selected_models, definition_id), "error")
              |> reload.(socket.assigns.workbench)
          end
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def note_analysis_progress(socket, definition_id, step, detail, reload) do
    socket
    |> assign(
      :import_editor_analysis_states,
      Map.update(socket.assigns.import_editor_analysis_states, definition_id, default_analysis_state(), fn state ->
        state
        |> Map.put(:loading, true)
        |> Map.put(:step, step)
        |> Map.put(:detail, detail)
      end)
    )
    |> reload.(socket.assigns.workbench)
  end

  def note_execution_progress(socket, definition_id, phase, current, total, detail, reload) do
    {detail_text, eta} = decompose_progress_detail(detail)
    translated_phase = translate_execution_phase(phase)

    socket
    |> assign(
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

  def finish_analysis(socket, ref, result, reload, append_output) do
    case Map.get(socket.assigns.import_editor_analysis_task_refs, ref) do
      nil ->
        socket

      definition_id ->
        analysis_state = Map.get(socket.assigns.import_editor_analysis_states, definition_id, default_analysis_state())

        socket =
          socket
          |> assign(:import_editor_analysis_task_refs, Map.delete(socket.assigns.import_editor_analysis_task_refs, ref))
          |> assign(:import_editor_analysis_states, Map.delete(socket.assigns.import_editor_analysis_states, definition_id))

        case result do
          {:ok, report} ->
            attrs =
              %{
                wxr_file_path: analysis_state.file_path,
                last_analysis_result: report
              }
              |> maybe_put(:name, suggested_definition_name(report))

            case ImportDefinitions.update_definition(definition_id, attrs) do
              {:ok, _definition} -> reload.(socket, socket.assigns.workbench)

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

  def finish_execution(socket, ref, result, reload, append_output) do
    case Map.get(socket.assigns.import_editor_execution_task_refs, ref) do
      nil ->
        socket

      definition_id ->
        previous_state = Map.get(socket.assigns.import_editor_execution_states, definition_id, default_execution_state())

        socket =
          socket
          |> assign(:import_editor_execution_task_refs, Map.delete(socket.assigns.import_editor_execution_task_refs, ref))

        case result do
          {:ok, execution_result} ->
            socket
            |> assign(
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
            |> assign(
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
            |> assign(
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
        case Map.get(socket.assigns.import_editor_analysis_task_refs, ref) do
          nil -> socket

          definition_id ->
            socket
            |> assign(:import_editor_analysis_task_refs, Map.delete(socket.assigns.import_editor_analysis_task_refs, ref))
            |> assign(:import_editor_analysis_states, Map.delete(socket.assigns.import_editor_analysis_states, definition_id))
            |> append_output.(translated("activity.import"), message, nil, "error")
            |> reload.(socket.assigns.workbench)
        end

      :execution ->
        case Map.get(socket.assigns.import_editor_execution_task_refs, ref) do
          nil -> socket

          definition_id ->
            previous_state = Map.get(socket.assigns.import_editor_execution_states, definition_id, default_execution_state())

            socket
            |> assign(:import_editor_execution_task_refs, Map.delete(socket.assigns.import_editor_execution_task_refs, ref))
            |> assign(
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

  attr :import_editor, :map, required: true

  def import_editor(assigns) do
    assigns =
      assigns
      |> assign(:report, Map.get(assigns.import_editor, :report))
      |> assign(:analysis_state, Map.get(assigns.import_editor, :analysis_state, default_analysis_state()))
      |> assign(:execution_state, Map.get(assigns.import_editor, :execution_state))
      |> assign(:counts, Map.get(assigns.import_editor, :importable_counts, %{total: 0, tags: 0, posts: 0, media: 0, pages: 0}))
      |> assign(:sections, Map.get(assigns.import_editor, :sections, default_sections()))
      |> assign(:detail_posts, detail_items(Map.get(assigns.import_editor, :report), :posts))
      |> assign(:detail_pages, detail_items(Map.get(assigns.import_editor, :report), :pages))
      |> assign(:detail_media, detail_items(Map.get(assigns.import_editor, :report), :media))
      |> assign(:post_conflicts, Enum.filter(detail_items(Map.get(assigns.import_editor, :report), :posts), &(&1.status == "conflict")))
      |> assign(:page_conflicts, Enum.filter(detail_items(Map.get(assigns.import_editor, :report), :pages), &(&1.status == "conflict")))
      |> assign(:post_items, Enum.filter(detail_items(Map.get(assigns.import_editor, :report), :posts), &(Map.get(&1, :post_type, "post") == "post")))
      |> assign(:other_items, Enum.reject(detail_items(Map.get(assigns.import_editor, :report), :posts), &(Map.get(&1, :post_type, "post") == "post")))

    ~H"""
    <div class="import-analysis" data-testid="import-editor">
      <form class="import-analysis-header" data-testid="import-editor-form" phx-change="change_import_editor_definition">
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
          <button type="button" phx-click="select_import_uploads_folder"><%= translated("Open") %></button>
        </div>

        <div class="import-file-row">
          <label><%= translated("importAnalysis.wxrFile") %></label>
          <div class={["import-file-path", if(blank?(@import_editor.wxr_file_path), do: "placeholder")]}>
            <%= @import_editor.wxr_file_path || translated("importAnalysis.selectFileToAnalyze") %>
          </div>
          <button class="import-analyze-btn" type="button" phx-click="select_import_wxr_file"><%= translated("importAnalysis.selectAndAnalyze") %></button>
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

            <button class="import-execute-btn" type="button" phx-click="execute_import_editor" disabled={@counts.total == 0}>
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
          <.conflict_section title={translated("importAnalysis.postSlugConflicts")} items={@post_conflicts} expanded={@sections.post_conflicts} section="post_conflicts" />
        <% end %>

        <%= if Enum.any?(@page_conflicts) do %>
          <.conflict_section title={translated("importAnalysis.pageSlugConflicts")} items={@page_conflicts} expanded={@sections.page_conflicts} section="page_conflicts" />
        <% end %>

        <%= if Enum.any?(@post_items) do %>
          <.post_detail_section title={translated("importAnalysis.postsWithCount", %{count: length(@post_items)})} items={@post_items} expanded={@sections.posts} section="posts" />
        <% end %>

        <%= if Enum.any?(@other_items) do %>
          <.post_detail_section title={translated("importAnalysis.otherWithCount", %{count: length(@other_items)})} items={@other_items} expanded={@sections.other} section="other" show_type={true} />
        <% end %>

        <%= if Enum.any?(@detail_pages) do %>
          <.post_detail_section title={translated("importAnalysis.pagesWithCount", %{count: length(@detail_pages)})} items={@detail_pages} expanded={@sections.pages} section="pages" />
        <% end %>

        <%= if Enum.any?(@detail_media) do %>
          <.media_detail_section title={translated("importAnalysis.mediaWithCount", %{count: length(@detail_media)})} items={@detail_media} expanded={@sections.media} section="media" />
        <% end %>

        <%= if Enum.any?(Map.get(@report.items, :categories, [])) or Enum.any?(Map.get(@report.items, :tags, [])) do %>
          <section class="import-detail-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section="taxonomy">
              <span><%= translated("importAnalysis.taxonomyTitle") %></span>
              <span class="toggle-icon"><%= if @sections.taxonomy, do: "▾", else: "▸" %></span>
            </button>

            <%= if @sections.taxonomy do %>
              <div class="taxonomy-analyze-row">
                <div class="taxonomy-analyze-dropdown">
                  <button class="taxonomy-analyze-btn" type="button" phx-click="toggle_import_ai_model_selector"><%= translated("importAnalysis.analyzeWith") %></button>
                  <%= if @import_editor.model_selector_open? do %>
                    <div class="taxonomy-model-dropdown">
                      <%= for model <- @import_editor.available_models do %>
                        <button class="taxonomy-model-option" type="button" phx-click="select_import_ai_model" phx-value-model={model.id}>
                          <%= model.provider_name || model.provider || translated("importAnalysis.unknown") %>: <%= model.name || model.id %>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <button class="taxonomy-analyze-btn" type="button" phx-click="analyze_import_taxonomy_ai" disabled={Enum.empty?(@import_editor.available_models) and not @import_editor.offline?}>
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
                />
                <.taxonomy_group
                  title={translated("importAnalysis.tags")}
                  items={Map.get(@report.items, :tags, [])}
                  suggestions={Map.get(@import_editor.taxonomy_terms, :tags, [])}
                  edit={@import_editor.taxonomy_edit}
                  type="tags"
                />
              </div>
            <% end %>
          </section>
        <% end %>

        <% macros = Map.get(@report, :macros, %{}) %>
        <%= if Enum.any?(Map.get(macros, :discovered, [])) do %>
          <section class="import-detail-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section="macros">
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

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :expanded, :boolean, required: true
  attr :section, :string, required: true

  def conflict_section(assigns) do
    ~H"""
    <section class="import-detail-section conflicts-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section={@section}>
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
                  <form phx-change="change_import_conflict_resolution">
                    <input type="hidden" name="item_type" value={Map.get(item, :item_type)} />
                    <input type="hidden" name="item_name" value={Map.get(item, :slug)} />
                    <select class="resolution-select" name="resolution">
                      <option value="skip" selected={Map.get(item, :resolution) == "skip"}><%= translated("importAnalysis.ignore") %></option>
                      <option value="merge" selected={Map.get(item, :resolution) == "merge"}><%= translated("importAnalysis.overwrite") %></option>
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

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :expanded, :boolean, required: true
  attr :section, :string, required: true
  attr :show_type, :boolean, default: false

  def post_detail_section(assigns) do
    ~H"""
    <section class="import-detail-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section={@section}>
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

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :expanded, :boolean, required: true
  attr :section, :string, required: true

  def media_detail_section(assigns) do
    ~H"""
    <section class="import-detail-section">
      <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section={@section}>
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

  attr :label, :string, required: true
  attr :stats, :map, required: true

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

  attr :label, :string, required: true
  attr :stats, :map, required: true

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

  attr :label, :string, required: true
  attr :stats, :map, required: true

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

  attr :label, :string, required: true
  attr :stats, :map, required: true

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

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :suggestions, :list, required: true
  attr :edit, :map, default: nil
  attr :type, :string, required: true

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
            <form class="import-taxonomy-edit-form" phx-submit="save_import_taxonomy_edit">
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
              <button class="taxonomy-edit-btn ghost" type="button" phx-click="cancel_import_taxonomy_edit" title={translated("Cancel")}>×</button>
              <%= if present?(item.mapped_to) do %>
                <button class="taxonomy-clear-btn" type="button" phx-click="clear_import_taxonomy_mapping" phx-value-type={@type} phx-value-name={item.name} title={translated("importAnalysis.clearMapping")}>×</button>
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
                  phx-value-type={@type}
                  phx-value-name={item.name}
                  phx-value-mapped_to={Map.get(item, :mapped_to) || ""}
                ><%= item.mapped_to %></button>
                <button class="taxonomy-clear-btn" type="button" phx-click="clear_import_taxonomy_mapping" phx-value-type={@type} phx-value-name={item.name} title={translated("importAnalysis.clearMapping")}>×</button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp update_conflict_resolution(report, item_type, item_name, resolution) do
    report
    |> update_in([:conflicts], fn conflicts ->
      Enum.map(conflicts || [], fn conflict ->
        if conflict.item_type == item_type and conflict.item_name == item_name do
          %{conflict | resolution: resolution}
        else
          conflict
        end
      end)
    end)
    |> update_in([:items], &update_conflict_bucket(&1, item_type, item_name, resolution))
    |> update_in([:details], &update_conflict_bucket(&1, item_type, item_name, resolution))
  end

  defp update_conflict_bucket(nil, _item_type, _item_name, _resolution), do: nil

  defp update_conflict_bucket(buckets, item_type, item_name, resolution) do
    bucket_key = if(item_type == "page", do: :pages, else: if(item_type == "media", do: :media, else: :posts))

    update_in(buckets, [bucket_key], fn items ->
      Enum.map(items || [], fn item ->
        identity = Map.get(item, :slug) || Map.get(item, :filename)

        if identity == item_name do
          Map.put(item, :resolution, resolution)
        else
          item
        end
      end)
    end)
  end

  defp update_taxonomy_mapping(report, type, name, mapped_to) do
    bucket_key = if(type == "categories", do: :categories, else: :tags)
    normalized_value = mapped_to |> to_string() |> String.trim() |> blank_to_nil()

    updated_report =
      update_in(report, [:items, bucket_key], fn items ->
        Enum.map(items || [], fn item ->
          if item.name == name do
            %{item | mapped_to: normalized_value}
          else
            item
          end
        end)
      end)

    Map.put(updated_report, stat_key(bucket_key), rebuild_taxonomy_stats(get_in(updated_report, [:items, bucket_key]) || []))
  end

  defp rebuild_taxonomy_stats(items) do
    %{
      existing_count: Enum.count(items, & &1.exists_in_project),
      mapped_count: Enum.count(items, &(not &1.exists_in_project and present?(&1.mapped_to))),
      new_count: Enum.count(items, &(not &1.exists_in_project and not present?(&1.mapped_to)))
    }
  end

  defp stat_key(:categories), do: :category_stats
  defp stat_key(:tags), do: :tag_stats

  defp importable_counts(nil), do: %{total: 0, tags: 0, posts: 0, media: 0, pages: 0}

  defp importable_counts(report) do
    tag_count =
      (Map.get(report.items, :categories, []) ++ Map.get(report.items, :tags, []))
      |> Enum.count(&(not &1.exists_in_project and not present?(&1.mapped_to)))

    posts = importable_entity_count(Map.get(report.items, :posts, []))
    pages = importable_entity_count(Map.get(report.items, :pages, []))
    media = importable_entity_count(Map.get(report.items, :media, []))

    %{total: tag_count + posts + pages + media, tags: tag_count, posts: posts, media: media, pages: pages}
  end

  defp importable_entity_count(items) do
    Enum.count(items || [], fn item ->
      item.status == "new" or (item.status == "conflict" and Map.get(item, :resolution, "ignore") not in ["ignore", "skip"])
    end)
  end

  defp detail_items(nil, _bucket), do: []

  defp detail_items(report, bucket) do
    get_in(report, [:details, bucket]) || get_in(report, [:items, bucket]) || []
  end

  defp execution_progress_width(state) do
    current = Map.get(state, :current, 0)
    total = Map.get(state, :total, 0)

    cond do
      total <= 0 -> 0
      true -> min(current / total * 100, 100)
    end
  end

  defp joined_or_none(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp joined_or_none(_values), do: translated("importAnalysis.none")

  defp status_badge_class(status), do: ["status-badge", status]

  defp distribution_width(value, rows, key) do
    max_value = rows |> Enum.map(&Map.get(&1, key, 0)) |> Enum.max(fn -> 1 end)
    max(8, value / max(max_value, 1) * 100)
  end

  defp total_stats(stats), do: stats.new_count + stats.update_count + stats.conflict_count + stats.duplicate_count
  defp total_media_stats(stats), do: total_stats(stats) + stats.missing_count

  defp taxonomy_pill_class(item) do
    cond do
      item.exists_in_project -> "import-taxonomy-pill exists"
      present?(item.mapped_to) -> "import-taxonomy-pill mapped"
      true -> "import-taxonomy-pill new-tax"
    end
  end

  defp taxonomy_item_editing?(%{type: type, name: name}, type, name), do: true
  defp taxonomy_item_editing?(_edit, _type, _name), do: false

  defp taxonomy_mapping_tooltip(item) do
    action =
      if present?(item.mapped_to),
        do: translated("importAnalysis.mappingActionEdit"),
        else: translated("importAnalysis.mappingActionAdd")

    translated("importAnalysis.mappingTooltip", %{action: action})
  end

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  defp translate_phase(step) when is_binary(step) do
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

  defp translate_phase(other), do: other

  defp translate_execution_phase(phase) when is_binary(phase) do
    case phase do
      "tags" -> translated("importAnalysis.phase.tags")
      "posts" -> translated("importAnalysis.phase.posts")
      "media" -> translated("importAnalysis.phase.media")
      "pages" -> translated("importAnalysis.phase.pages")
      "complete" -> translated("importAnalysis.phase.complete")
      other -> other
    end
  end

  defp translate_execution_phase(other), do: other

  defp decompose_progress_detail(%{detail: detail, eta: eta}), do: {to_string_or_nil(detail), eta}
  defp decompose_progress_detail(detail) when is_binary(detail) or is_nil(detail), do: {detail, nil}
  defp decompose_progress_detail(detail), do: {to_string_or_nil(detail), nil}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: inspect(value)

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

  defp present?(value), do: value not in [nil, ""]
  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp default_analysis_state do
    %{loading: false, step: nil, detail: nil, file_path: nil, ref: nil}
  end

  defp default_sections do
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

  defp default_execution_state do
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

  defp selected_model(assigns, definition_id) do
    Map.get(assigns.import_editor_selected_models, definition_id) || preferred_model(assigns)
  end

  defp preferred_model(assigns) do
    preference_key = if Map.get(assigns, :offline_mode, true), do: :airplane_chat, else: :chat

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

  defp auto_mapped_count(previous_report, next_report) do
    previous_count =
      (Map.get(previous_report.items, :categories, []) ++ Map.get(previous_report.items, :tags, []))
      |> Enum.count(&present?(&1.mapped_to))

    next_count =
      (Map.get(next_report.items, :categories, []) ++ Map.get(next_report.items, :tags, []))
      |> Enum.count(&present?(&1.mapped_to))

    max(next_count - previous_count, 0)
  end

  defp apply_taxonomy_mappings(report, analysis) do
    report
    |> update_in([:items, :categories], &apply_taxonomy_mapping_bucket(&1, Map.get(analysis, :category_mappings, %{})))
    |> update_in([:items, :tags], &apply_taxonomy_mapping_bucket(&1, Map.get(analysis, :tag_mappings, %{})))
    |> then(fn updated_report ->
      updated_report
      |> Map.put(:category_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :categories]) || []))
      |> Map.put(:tag_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :tags]) || []))
    end)
  end

  defp apply_taxonomy_mapping_bucket(items, mappings) do
    Enum.map(items || [], fn item ->
      case Map.fetch(mappings, item.name) do
        {:ok, mapped_to} -> %{item | mapped_to: mapped_to}
        :error -> item
      end
    end)
  end

  defp existing_taxonomy_terms(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    %{
      categories: Enum.uniq(Map.get(metadata, :categories, []) || []),
      tags: project_id |> Tags.list_tags() |> Enum.map(& &1.name) |> Enum.uniq()
    }
  end

  defp normalize_taxonomy_mapping_value(project_id, type, mapped_to) do
    normalized_value = mapped_to |> to_string() |> String.trim() |> blank_to_nil()

    case normalized_value do
      nil -> nil
      value ->
        project_id
        |> existing_taxonomy_terms()
        |> Map.get(String.to_existing_atom(type), [])
        |> Enum.find(fn term -> String.downcase(term) == String.downcase(value) end)
    end
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_author(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    Map.get(metadata, :default_author)
  end

  defp suggested_definition_name(report) do
    get_in(report, [:site_info, :url]) || get_in(report, [:site_info, :title])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
end
