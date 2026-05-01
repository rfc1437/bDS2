defmodule BDS.Desktop.ShellLive.SettingsEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.ShellData
  alias BDS.Repo
  alias BDS.Templates.Template

  alias BDS.Desktop.ShellLive.SettingsEditor.AISettings
  alias BDS.Desktop.ShellLive.SettingsEditor.EditorSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories
  alias BDS.Desktop.ShellLive.SettingsEditor.MCPConfig
  alias BDS.Desktop.ShellLive.SettingsEditor.ProjectSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.PublishingSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.StyleEditor

  embed_templates "settings_editor_html/*"

  @settings_sections ~w(project editor content ai technology publishing data mcp)
  @supported_languages ["en", "de", "fr", "it", "es"]

  defdelegate update_project_draft(socket, params, reload), to: ProjectSettings
  defdelegate save_project(socket, reload, append_output), to: ProjectSettings
  defdelegate update_editor_draft(socket, params, reload), to: EditorSettings
  defdelegate save_editor(socket, reload, append_output), to: EditorSettings
  defdelegate update_publishing_draft(socket, params, reload), to: PublishingSettings
  defdelegate save_publishing(socket, reload, append_output), to: PublishingSettings
  defdelegate clear_publishing(socket, reload, append_output), to: PublishingSettings
  defdelegate update_ai_draft(socket, params, reload), to: AISettings
  defdelegate refresh_ai_models(socket, endpoint_key, reload, append_output), to: AISettings
  defdelegate save_ai(socket, reload, append_output), to: AISettings
  defdelegate reset_ai_prompt(socket, reload, append_output), to: AISettings
  defdelegate update_new_category(socket, name, reload), to: ManagedCategories
  defdelegate add_category(socket, reload, append_output), to: ManagedCategories
  defdelegate reset_categories(socket, reload, append_output), to: ManagedCategories
  defdelegate save_category(socket, params, reload, append_output), to: ManagedCategories
  defdelegate remove_category(socket, category, reload, append_output), to: ManagedCategories
  defdelegate toggle_mcp_agent(socket, agent, reload, append_output), to: MCPConfig
  defdelegate select_style_theme(socket, theme, reload), to: StyleEditor
  defdelegate change_style_preview_mode(socket, mode, reload), to: StyleEditor
  defdelegate apply_style_theme(socket, reload, append_output), to: StyleEditor
  defdelegate theme_display_name(theme), to: StyleEditor
  defdelegate protected_category?(category), to: ManagedCategories

  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :settings} ->
        socket
        |> assign(:settings_editor, build_settings(socket.assigns))
        |> assign(:style_editor, nil)

      %{type: :style} ->
        socket
        |> assign(:settings_editor, nil)
        |> assign(:style_editor, StyleEditor.build_style(socket.assigns))

      _other ->
        socket
        |> assign(:settings_editor, nil)
        |> assign(:style_editor, nil)
    end
  end

  def update_search(socket, query, reload) do
    socket
    |> assign(:settings_editor_search, to_string(query || ""))
    |> reload.(socket.assigns.workbench)
  end

  def build_settings(%{projects: %{active_project_id: nil}}), do: nil

  def build_settings(assigns) do
    metadata = ProjectSettings.project_metadata(assigns)

    project_form =
      Map.merge(
        ProjectSettings.project_form(metadata),
        Map.get(assigns, :settings_editor_project_draft, %{})
      )

    editor_form =
      Map.merge(EditorSettings.editor_form(), Map.get(assigns, :settings_editor_editor_draft, %{}))

    ai_form =
      Map.merge(AISettings.ai_form(assigns), Map.get(assigns, :settings_editor_ai_draft, %{}))

    publishing_form =
      Map.merge(
        PublishingSettings.publishing_form(metadata),
        Map.get(assigns, :settings_editor_publishing_draft, %{})
      )

    query = Map.get(assigns, :settings_editor_search, "")
    selected_section = current_settings_section(assigns)
    visible_sections = visible_settings_sections(query)

    %{
      search_query: query,
      selected_section: selected_section,
      active_sections: visible_sections,
      project: project_form,
      editor: editor_form,
      categories: ManagedCategories.category_rows(metadata),
      ai: ai_form,
      technology: ProjectSettings.technology_form(project_form),
      publishing: publishing_form,
      mcp: MCPConfig.mcp_rows(),
      new_category: Map.get(assigns, :settings_editor_new_category, ""),
      project_data_path: Map.get(assigns.current_project || %{}, :data_path) || "",
      project_data_default_path: Map.get(assigns.current_project || %{}, :project_path) || "",
      template_options: template_options(assigns.projects.active_project_id),
      online_endpoint_models: AISettings.endpoint_model_options(assigns, :online),
      offline_endpoint_models: AISettings.endpoint_model_options(assigns, :airplane),
      project_visible?:
        section_matches?(
          query,
          ~w(project name description url language author category posts bookmarklet)
        ),
      editor_visible?:
        section_matches?(query, ~w(editor mode markdown preview diff wrap unchanged)),
      content_visible?: section_matches?(query, ~w(content categories templates lists blogmark)),
      ai_visible?:
        section_matches?(
          query,
          ~w(ai assistant model prompt airplane offline online endpoint url api key chat title image)
        ),
      technology_visible?:
        section_matches?(query, ~w(technology runtime semantic similarity embedding scripting)),
      publishing_visible?:
        section_matches?(query, ~w(publishing ssh scp rsync host user remote path)),
      mcp_visible?:
        section_matches?(
          query,
          ~w(mcp claude copilot gemini opencode mistral codex agent server)
        ),
      data_visible?: section_matches?(query, ~w(data rebuild maintenance folder filesystem)),
      supported_languages: @supported_languages,
      protected_categories: ManagedCategories.protected_categories()
    }
  end

  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  defp current_settings_section(assigns) do
    meta = current_tab_meta(assigns)

    meta
    |> Map.get(:sidebar_item_id, "settings-project")
    |> to_string()
    |> String.replace_prefix("settings-", "")
    |> case do
      section when section in @settings_sections -> section
      _other -> "project"
    end
  end

  defp current_tab_meta(assigns) do
    current_tab = Map.get(assigns, :current_tab)

    case current_tab do
      %{type: type, id: id} -> Map.get(assigns[:tab_meta] || %{}, {type, id}, %{})
      _other -> %{}
    end
  end

  defp visible_settings_sections(query) do
    Enum.filter(@settings_sections, fn section ->
      case section do
        "project" ->
          section_matches?(query, ~w(project name description data url language author bookmarklet))

        "editor" ->
          section_matches?(query, ~w(editor mode markdown preview diff wrap unchanged))

        "content" ->
          section_matches?(query, ~w(content categories templates lists blogmark))

        "ai" ->
          section_matches?(
            query,
            ~w(ai assistant model prompt airplane offline online endpoint url api key chat title image)
          )

        "technology" ->
          section_matches?(query, ~w(technology semantic similarity runtime scripting embedding))

        "publishing" ->
          section_matches?(query, ~w(publishing ssh scp rsync host user remote path))

        "data" ->
          section_matches?(query, ~w(data rebuild maintenance links thumbnails filesystem))

        "mcp" ->
          section_matches?(query, ~w(mcp claude copilot gemini opencode mistral codex agent server))
      end
    end)
  end

  defp template_options(project_id) do
    %{
      post:
        Repo.all(
          from template in Template,
            where: template.project_id == ^project_id and template.kind == :post,
            order_by: [asc: template.title],
            select: %{slug: template.slug, title: template.title}
        ),
      list:
        Repo.all(
          from template in Template,
            where: template.project_id == ^project_id and template.kind == :list,
            order_by: [asc: template.title],
            select: %{slug: template.slug, title: template.title}
        )
    }
  end

  defp section_matches?("", _keywords), do: true

  defp section_matches?(query, keywords),
    do: Enum.any?(keywords, &String.contains?(&1, String.downcase(query)))
end
