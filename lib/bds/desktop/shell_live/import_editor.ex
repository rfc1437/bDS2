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
            existing_terms = socket.assigns.projects.active_project_id |> Tags.list_tags() |> Enum.map(& &1.name)
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
              existing_terms: existing_terms,
              execution_state: execution_state,
              importable_counts: importable_counts(report),
              sections: sections,
              selected_model: selected_model,
              selected_model_label: selected_model_label(selected_model, available_models),
              model_selector_open?: Map.get(socket.assigns.import_editor_model_selectors_open, definition.id, false),
              available_models: available_models,
              offline?: Map.get(socket.assigns, :offline_mode, true),
              is_loading: false
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

          case ImportAnalysis.analyze_wxr(project_id, wxr_file_path, definition.uploads_folder_path) do
            {:ok, report} ->
              {:ok, _definition} =
                ImportDefinitions.update_definition(definition_id, %{
                  wxr_file_path: wxr_file_path,
                  last_analysis_result: report
                })

              socket
              |> assign(:import_editor_execution_states, Map.delete(socket.assigns.import_editor_execution_states, definition_id))
              |> append_output.(translated("activity.import"), translated("importAnalysis.analyzingWxr"), Path.basename(wxr_file_path), "info")
              |> reload.(socket.assigns.workbench)

            {:error, %{message: message}} ->
              socket
              |> append_output.(translated("activity.import"), message, nil, "error")
              |> reload.(socket.assigns.workbench)
          end

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

  def execute_import(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
      project_id = socket.assigns.projects.active_project_id
      default_author = default_author(project_id)

      case ImportExecution.execute_import(project_id, report,
             uploads_folder_path: definition.uploads_folder_path,
             default_author: default_author
           ) do
        {:ok, result} ->
          counts = importable_counts(report)

          socket
          |> assign(:import_editor_execution_states, Map.put(socket.assigns.import_editor_execution_states, definition_id, %{completed: true, error: nil, count: counts.total, result: result}))
          |> append_output.(translated("activity.import"), translated("importAnalysis.importComplete", %{count: counts.total}), nil, "info")
          |> reload.(socket.assigns.workbench)

        {:error, %{message: message}} ->
          socket
          |> assign(:import_editor_execution_states, Map.put(socket.assigns.import_editor_execution_states, definition_id, %{completed: false, error: message, count: 0, result: nil}))
          |> append_output.(translated("activity.import"), message, nil, "error")
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

  def change_taxonomy_mapping(socket, %{"type" => type, "name" => name, "mapped_to" => mapped_to}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition),
         updated_report <- update_taxonomy_mapping(report, type, name, mapped_to),
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report}) do
      reload.(socket, socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def toggle_section(socket, section, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         section_key when section_key in ["conflicts", "taxonomy", "macros"] <- section do
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
          updated_report = auto_map_taxonomies(report, socket.assigns.projects.active_project_id |> Tags.list_tags() |> Enum.map(& &1.name))
          {:ok, _definition} = ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report})
          mapped_count = auto_mapped_count(report, updated_report)

          socket
          |> append_output.(translated("activity.import"), translated("importAnalysis.mappedCount", %{count: mapped_count}), Map.get(socket.assigns.import_editor_selected_models, definition_id), "info")
          |> reload.(socket.assigns.workbench)
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  attr :import_editor, :map, required: true

  def import_editor(assigns) do
    assigns =
      assigns
      |> assign(:report, Map.get(assigns.import_editor, :report))
      |> assign(:execution_state, Map.get(assigns.import_editor, :execution_state))
      |> assign(:counts, Map.get(assigns.import_editor, :importable_counts, %{total: 0, tags: 0, posts: 0, media: 0, pages: 0}))
      |> assign(:sections, Map.get(assigns.import_editor, :sections, default_sections()))

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

      <%= if @report do %>
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
                  </div>
                  <span class="distribution-count"><%= row.post_count %> / <%= row.media_count %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

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

        <%= if Enum.any?(Map.get(@report, :conflicts, [])) do %>
          <section class="import-detail-section conflicts-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section="conflicts">
              <span><%= translated("importAnalysis.postSlugConflicts") %></span>
              <span class="toggle-icon"><%= if @sections.conflicts, do: "▾", else: "▸" %></span>
            </button>

            <%= if @sections.conflicts do %>
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
                  <%= for conflict <- @report.conflicts do %>
                    <tr>
                      <td class="slug-cell"><%= conflict.item_name %></td>
                      <td><%= conflict.source_title %></td>
                      <td><%= conflict.existing_title || translated("importAnalysis.none") %></td>
                      <td>
                        <form phx-change="change_import_conflict_resolution">
                          <input type="hidden" name="item_type" value={conflict.item_type} />
                          <input type="hidden" name="item_name" value={conflict.item_name} />
                          <select class="resolution-select" name="resolution">
                            <option value="skip" selected={conflict.resolution == "skip"}><%= translated("importAnalysis.ignore") %></option>
                            <option value="merge" selected={conflict.resolution == "merge"}><%= translated("importAnalysis.overwrite") %></option>
                            <option value="import" selected={conflict.resolution == "import"}><%= translated("importAnalysis.importNewSlug") %></option>
                          </select>
                        </form>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </section>
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
                <.taxonomy_group title={translated("importAnalysis.categories")} items={Map.get(@report.items, :categories, [])} existing_terms={@import_editor.existing_terms} type="categories" />
                <.taxonomy_group title={translated("importAnalysis.tags")} items={Map.get(@report.items, :tags, [])} existing_terms={@import_editor.existing_terms} type="tags" />
              </div>
            <% end %>
          </section>
        <% end %>

        <%= if Enum.any?(Map.get(@report, :macros, [])) do %>
          <section class="import-detail-section">
            <button class="import-section-toggle" type="button" phx-click="toggle_import_section" phx-value-section="macros">
              <span><%= translated("importAnalysis.macrosWithCount", %{count: length(@report.macros)}) %></span>
              <span class="toggle-icon"><%= if @sections.macros, do: "▾", else: "▸" %></span>
            </button>

            <%= if @sections.macros do %>
              <div class="macros-list">
                <%= for macro <- @report.macros do %>
                  <div class="macro-item unmapped">
                    <div class="macro-header">
                      <span class="macro-name"><%= macro.name %></span>
                      <span class="macro-status-badge unmapped"><%= translated("importAnalysis.macroStatusUnknown") %></span>
                      <span class="macro-count"><%= translated("importAnalysis.macroUses", %{count: macro.usage_count}) %></span>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </section>
        <% end %>
      <% else %>
        <div class="import-empty-state">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
            <path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"></path>
          </svg>
          <p><%= translated("importAnalysis.emptyState") %></p>
        </div>
      <% end %>
    </div>
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
  attr :existing_terms, :list, required: true
  attr :type, :string, required: true

  def taxonomy_group(assigns) do
    ~H"""
    <div class="taxonomy-group">
      <h4><%= @title %></h4>
      <div class="import-taxonomy-list">
        <%= for item <- @items do %>
          <form class="import-taxonomy-form" phx-change="change_import_taxonomy_mapping">
            <input type="hidden" name="type" value={@type} />
            <input type="hidden" name="name" value={item.name} />
            <span class={taxonomy_pill_class(item)}><%= item.name %></span>
            <select name="mapped_to">
              <option value=""><%= translated("importAnalysis.mapToPlaceholder") %></option>
              <%= for term <- @existing_terms do %>
                <option value={term} selected={item.mapped_to == term}><%= term %></option>
              <% end %>
            </select>
          </form>
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
      item.status == "new" or (item.status == "conflict" and Map.get(item, :resolution, "skip") != "skip")
    end)
  end

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

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
  defp present?(value), do: value not in [nil, ""]
  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp default_execution_state do
    %{completed: false, error: nil, count: 0, result: nil}
  end

  defp default_sections do
    %{conflicts: true, taxonomy: true, macros: true}
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

  defp auto_map_taxonomies(report, existing_terms) do
    report
    |> update_in([:items, :categories], &auto_map_taxonomy_items(&1, existing_terms))
    |> update_in([:items, :tags], &auto_map_taxonomy_items(&1, existing_terms))
    |> then(fn updated_report ->
      updated_report
      |> Map.put(:category_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :categories]) || []))
      |> Map.put(:tag_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :tags]) || []))
    end)
  end

  defp auto_map_taxonomy_items(items, existing_terms) do
    Enum.map(items || [], fn item ->
      cond do
        item.exists_in_project or present?(item.mapped_to) -> item
        suggestion = best_taxonomy_match(item.name, existing_terms) -> %{item | mapped_to: suggestion}
        true -> item
      end
    end)
  end

  defp best_taxonomy_match(term, existing_terms) do
    normalized_term = normalize_term(term)

    existing_terms
    |> Enum.map(fn candidate -> {candidate, String.jaro_distance(normalized_term, normalize_term(candidate))} end)
    |> Enum.max_by(fn {_candidate, score} -> score end, fn -> {nil, 0.0} end)
    |> case do
      {candidate, score} when is_binary(candidate) and score >= 0.94 -> candidate
      _other -> nil
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

  defp normalize_term(term) do
    term
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "")
  end

  defp default_author(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    Map.get(metadata, :default_author)
  end
end
