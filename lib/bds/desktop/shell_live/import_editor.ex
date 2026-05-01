defmodule BDS.Desktop.ShellLive.ImportEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.AI
  alias BDS.Desktop.ShellData

  alias BDS.Desktop.ShellLive.ImportEditor.{
    AnalysisState,
    ConflictResolution,
    ProgressTracking,
    TaxonomyEditing
  }

  alias BDS.ImportDefinitions

  import AnalysisState,
    only: [
      default_analysis_state: 0,
      default_sections: 0,
      detail_items: 2,
      importable_counts: 1
    ]

  import ProgressTracking,
    only: [
      default_execution_state: 0,
      execution_progress_width: 1,
      format_eta: 1
    ]

  import TaxonomyEditing,
    only: [
      existing_taxonomy_terms: 1,
      taxonomy_item_editing?: 3,
      taxonomy_mapping_tooltip: 1,
      taxonomy_pill_class: 1
    ]

  defdelegate change_definition(socket, params, reload), to: AnalysisState
  defdelegate select_uploads_folder(socket, reload, append_output), to: AnalysisState
  defdelegate select_and_analyze(socket, reload, append_output), to: AnalysisState

  defdelegate note_analysis_progress(socket, definition_id, step, detail, reload),
    to: AnalysisState

  defdelegate finish_analysis(socket, ref, result, reload, append_output), to: AnalysisState

  defdelegate execute_import(socket, reload, append_output), to: ProgressTracking

  defdelegate note_execution_progress(
                socket,
                definition_id,
                phase,
                current,
                total,
                detail,
                reload
              ), to: ProgressTracking

  defdelegate finish_execution(socket, ref, result, reload, append_output), to: ProgressTracking

  defdelegate handle_task_down(socket, kind, ref, reason, reload, append_output),
    to: ProgressTracking

  defdelegate change_conflict_resolution(socket, params, reload), to: ConflictResolution

  defdelegate start_taxonomy_edit(socket, params, reload), to: TaxonomyEditing
  defdelegate cancel_taxonomy_edit(socket, reload), to: TaxonomyEditing
  defdelegate save_taxonomy_edit(socket, params, reload), to: TaxonomyEditing
  defdelegate clear_taxonomy_mapping(socket, params, reload), to: TaxonomyEditing
  defdelegate analyze_taxonomy_ai(socket, reload, append_output), to: TaxonomyEditing

  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :import, id: definition_id} ->
        case ImportDefinitions.get_definition(definition_id) do
          nil ->
            assign(socket, :import_editor, nil)

          definition ->
            report = ImportDefinitions.decode_analysis_result(definition)
            taxonomy_terms = existing_taxonomy_terms(socket.assigns.projects.active_project_id)

            analysis_state =
              Map.get(
                socket.assigns.import_editor_analysis_states,
                definition.id,
                default_analysis_state()
              )

            execution_state =
              Map.get(
                socket.assigns.import_editor_execution_states,
                definition.id,
                default_execution_state()
              )

            sections =
              Map.get(socket.assigns.import_editor_sections, definition.id, default_sections())

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
              model_selector_open?:
                Map.get(socket.assigns.import_editor_model_selectors_open, definition.id, false),
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

  def toggle_section(socket, section, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         section_key
         when section_key in [
                "post_conflicts",
                "page_conflicts",
                "posts",
                "other",
                "pages",
                "media",
                "taxonomy",
                "macros"
              ] <- section,
         section_atom when not is_nil(section_atom) <-
           BDS.BoundedAtoms.import_section(section_key) do
      next_sections =
        socket.assigns.import_editor_sections
        |> Map.get(definition_id, default_sections())
        |> Map.update!(section_atom, &(!&1))

      socket
      |> assign(
        :import_editor_sections,
        Map.put(socket.assigns.import_editor_sections, definition_id, next_sections)
      )
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def toggle_model_selector(socket, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      current = Map.get(socket.assigns.import_editor_model_selectors_open, definition_id, false)

      socket
      |> assign(
        :import_editor_model_selectors_open,
        Map.put(socket.assigns.import_editor_model_selectors_open, definition_id, not current)
      )
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def select_ai_model(socket, model_id, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> assign(
        :import_editor_selected_models,
        Map.put(socket.assigns.import_editor_selected_models, definition_id, model_id)
      )
      |> assign(
        :import_editor_model_selectors_open,
        Map.put(socket.assigns.import_editor_model_selectors_open, definition_id, false)
      )
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  attr(:import_editor, :map, required: true)

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

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)

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

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)
  attr(:show_type, :boolean, default: false)

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

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:expanded, :boolean, required: true)
  attr(:section, :string, required: true)

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

  attr(:label, :string, required: true)
  attr(:stats, :map, required: true)

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

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  defp present?(value), do: value not in [nil, ""]
  defp blank?(value), do: value in [nil, ""]
end
