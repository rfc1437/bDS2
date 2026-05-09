defmodule BDS.Desktop.ShellLive.SettingsEditor do
  @moduledoc false

  use Phoenix.LiveComponent
  use Gettext, backend: BDS.Gettext

  import Ecto.Query

  alias BDS.Repo
  alias BDS.Templates.Template

  alias BDS.Desktop.ShellLive.SettingsEditor.AISettings
  alias BDS.Desktop.ShellLive.SettingsEditor.EditorSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories
  alias BDS.Desktop.ShellLive.Notify
  alias BDS.Desktop.ShellLive.SettingsEditor.MCPConfig
  alias BDS.Desktop.ShellLive.SettingsEditor.ProjectSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.PublishingSettings
  alias BDS.Desktop.ShellLive.SettingsEditor.StyleEditor

  embed_templates("settings_editor_html/*")

  @settings_sections ~w(project editor content ai technology publishing data mcp)
  @supported_languages ["en", "de", "fr", "it", "es"]

  defdelegate theme_display_name(theme), to: StyleEditor
  defdelegate protected_category?(category), to: ManagedCategories

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save_project} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:action]))
    socket = ProjectSettings.save_project(socket, reload_callback(), append_output_callback())
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> initialize_state()
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    case assigns.current_tab do
      %{type: :settings} -> settings_editor(assigns)
      %{type: :style} -> style_editor(assigns)
      _other -> ~H""
    end
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_settings_search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:settings_editor_search, to_string(query || ""))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("change_settings_project", %{"settings_project" => params}, socket) do
    {:noreply, ProjectSettings.update_project_draft(socket, params, reload_callback())}
  end

  def handle_event("change_settings_editor", %{"settings_editor" => params}, socket) do
    {:noreply, EditorSettings.update_editor_draft(socket, params, reload_callback())}
  end

  def handle_event("save_settings_editor", _params, socket) do
    {:noreply, EditorSettings.save_editor(socket, reload_callback(), append_output_callback())}
  end

  def handle_event("save_settings_project", _params, socket) do
    socket = ProjectSettings.save_project(socket, reload_callback(), append_output_callback())
    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("change_settings_publishing", %{"settings_publishing" => params}, socket) do
    {:noreply, PublishingSettings.update_publishing_draft(socket, params, reload_callback())}
  end

  def handle_event("change_settings_ai", %{"settings_ai" => params}, socket) do
    {:noreply, AISettings.update_ai_draft(socket, params, reload_callback())}
  end

  def handle_event("refresh_settings_ai_models", %{"endpoint" => endpoint}, socket) do
    case BDS.BoundedAtoms.ai_endpoint(endpoint) do
      nil ->
        {:noreply, build_data(socket)}

      endpoint_key ->
        {:noreply,
         AISettings.refresh_ai_models(
           socket,
           endpoint_key,
           reload_callback(),
           append_output_callback()
         )}
    end
  end

  def handle_event("save_settings_ai", _params, socket) do
    socket = AISettings.save_ai(socket, reload_callback(), append_output_callback())
    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("reset_settings_ai_prompt", _params, socket) do
    {:noreply, AISettings.reset_ai_prompt(socket, reload_callback(), append_output_callback())}
  end

  def handle_event("save_settings_publishing", _params, socket) do
    socket =
      PublishingSettings.save_publishing(socket, reload_callback(), append_output_callback())

    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("clear_settings_publishing", _params, socket) do
    {:noreply,
     PublishingSettings.clear_publishing(socket, reload_callback(), append_output_callback())}
  end

  def handle_event("change_settings_new_category", %{"name" => name}, socket) do
    {:noreply, ManagedCategories.update_new_category(socket, name, reload_callback())}
  end

  def handle_event("add_settings_category", _params, socket) do
    socket = ManagedCategories.add_category(socket, reload_callback(), append_output_callback())
    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("reset_settings_categories", _params, socket) do
    socket =
      ManagedCategories.reset_categories(socket, reload_callback(), append_output_callback())

    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("save_settings_category", %{"category_settings" => params}, socket) do
    socket =
      ManagedCategories.save_category(socket, params, reload_callback(), append_output_callback())

    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("remove_settings_category", %{"category" => category}, socket) do
    socket =
      ManagedCategories.remove_category(
        socket,
        category,
        reload_callback(),
        append_output_callback()
      )

    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("toggle_settings_mcp_agent", %{"agent" => agent}, socket) do
    socket =
      MCPConfig.toggle_mcp_agent(socket, agent, reload_callback(), append_output_callback())

    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  def handle_event("select_style_theme", %{"theme" => theme}, socket) do
    {:noreply, StyleEditor.select_style_theme(socket, theme, reload_callback())}
  end

  def handle_event("change_style_preview_mode", %{"mode" => mode}, socket) do
    {:noreply, StyleEditor.change_style_preview_mode(socket, mode, reload_callback())}
  end

  def handle_event("apply_style_theme", _params, socket) do
    socket = StyleEditor.apply_style_theme(socket, reload_callback(), append_output_callback())
    notify_parent(:settings_changed)
    {:noreply, socket}
  end

  defp initialize_state(socket) do
    defaults = %{
      settings_editor_search: "",
      settings_editor_project_draft: %{},
      settings_editor_editor_draft: %{},
      settings_editor_ai_draft: %{},
      settings_editor_publishing_draft: %{},
      settings_editor_new_category: "",
      settings_editor_endpoint_models: %{},
      style_editor_theme: nil,
      style_editor_preview_mode: "auto"
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
    socket
    |> assign(:settings_editor, build_settings(socket.assigns))
    |> assign(:style_editor, build_style(socket.assigns))
  end

  @spec build_settings(map()) :: term()
  def build_settings(%{projects: %{active_project_id: nil}}), do: nil

  def build_settings(assigns) do
    metadata = ProjectSettings.project_metadata(assigns)

    project_form =
      Map.merge(
        ProjectSettings.project_form(metadata),
        Map.get(assigns, :settings_editor_project_draft, %{})
      )

    editor_form =
      Map.merge(
        EditorSettings.editor_form(),
        Map.get(assigns, :settings_editor_editor_draft, %{})
      )

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

  @spec build_style(map()) :: term()
  def build_style(%{projects: %{active_project_id: nil}}), do: nil

  def build_style(assigns) do
    StyleEditor.build_style(assigns)
  end

  defp reload_callback do
    fn socket, _workbench -> build_data(socket) end
  end

  defp append_output_callback do
    fn socket, title, message, _details, level ->
      Notify.output(title, message, level)
      socket
    end
  end

  defp notify_parent(message) do
    Notify.parent(message)
  end

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
          section_matches?(
            query,
            ~w(project name description data url language author bookmarklet)
          )

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
          section_matches?(
            query,
            ~w(mcp claude copilot gemini opencode mistral codex agent server)
          )
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
