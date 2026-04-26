defmodule BDS.Desktop.ShellLive.SettingsEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.AI
  alias BDS.Metadata
  alias BDS.Desktop.ShellData
  alias BDS.MCP.AgentConfig
  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting
  alias BDS.Templates.Template

  embed_templates "settings_editor_html/*"

  @settings_sections ~w(project editor content ai technology publishing data mcp)

  @themes [
    "default",
    "amber",
    "blue",
    "cyan",
    "fuchsia",
    "green",
    "grey",
    "indigo",
    "jade",
    "lime",
    "orange",
    "pink",
    "pumpkin",
    "purple",
    "red",
    "sand",
    "slate",
    "violet",
    "yellow",
    "zinc"
  ]

  @supported_languages ["en", "de", "fr", "it", "es"]
  @protected_categories MapSet.new(["article", "aside", "page", "picture"])
  @default_category_settings %{
    "article" => %{title: "article", render_in_lists: true, show_title: true},
    "picture" => %{title: "picture", render_in_lists: true, show_title: true},
    "aside" => %{title: "aside", render_in_lists: true, show_title: false},
    "page" => %{title: "page", render_in_lists: false, show_title: true}
  }
  @mcp_agents [
    %{id: :claude_code, label: "Claude Code", supported?: true},
    %{id: :claude_desktop, label: "Claude Desktop", supported?: false},
    %{id: :github_copilot, label: "GitHub Copilot", supported?: true},
    %{id: :gemini_cli, label: "Gemini CLI", supported?: false},
    %{id: :opencode, label: "OpenCode", supported?: false},
    %{id: :mistral_vibe, label: "Mistral Vibe", supported?: false},
    %{id: :openai_codex, label: "OpenAI Codex", supported?: false}
  ]

  def assign_socket(socket) do
    case socket.assigns[:current_tab] do
      %{type: :settings} ->
        socket
        |> assign(:settings_editor, build_settings(socket.assigns))
        |> assign(:style_editor, nil)

      %{type: :style} ->
        socket
        |> assign(:settings_editor, nil)
        |> assign(:style_editor, build_style(socket.assigns))

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

  def update_project_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_project_draft, normalize_project_params(params))
    |> reload.(socket.assigns.workbench)
  end

  def update_editor_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_editor_draft, normalize_editor_params(params))
    |> reload.(socket.assigns.workbench)
  end

  def save_editor(socket, reload, append_output) do
    attrs = editor_attrs(socket.assigns)

    with :ok <- put_global_setting("ui.preferred_editor_mode", attrs.default_mode),
         :ok <- put_global_setting("ui.git_diff_view_style", attrs.diff_view_style),
         :ok <- put_global_setting("ui.git_diff_word_wrap", boolean_string(attrs.wrap_long_lines)),
         :ok <- put_global_setting("ui.git_diff_hide_unchanged_regions", boolean_string(attrs.hide_unchanged_regions)) do
      socket
      |> assign(:settings_editor_editor_draft, %{})
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(translated("Editor Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def save_project(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.update_project_metadata(project_id, project_attrs(socket.assigns)) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_project_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def update_publishing_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_publishing_draft, normalize_publishing_params(params))
    |> reload.(socket.assigns.workbench)
  end

  def update_ai_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_ai_draft, normalize_ai_params(params))
    |> reload.(socket.assigns.workbench)
  end

  def refresh_ai_models(socket, endpoint_key, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with {:ok, endpoint} <- endpoint_refresh_attrs(endpoint_key, attrs),
         {:ok, models} <- AI.list_endpoint_models(endpoint) do
      socket
      |> assign(:settings_editor_endpoint_models, Map.put(socket.assigns[:settings_editor_endpoint_models] || %{}, endpoint_key, models))
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def save_ai(socket, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with :ok <- put_endpoint_preferences(:online, attrs.online_url, attrs.online_api_key, attrs.online_chat_model),
         :ok <- put_endpoint_preferences(:airplane, attrs.offline_url, attrs.offline_api_key, attrs.offline_chat_model),
         :ok <- AI.delete_endpoint(:mistral),
         :ok <- AI.set_airplane_mode(attrs.offline_mode),
         :ok <- maybe_put_model_preference(:chat, attrs.online_chat_model),
         :ok <- maybe_put_model_preference(:title, attrs.online_title_model),
         :ok <- maybe_put_model_preference(:image_analysis, attrs.online_image_analysis_model),
         :ok <- maybe_put_model_preference(:airplane_chat, attrs.offline_chat_model),
         :ok <- maybe_put_model_preference(:airplane_title, attrs.offline_title_model),
         :ok <- maybe_put_model_preference(:airplane_image_analysis, attrs.offline_image_analysis_model),
         :ok <- put_global_setting("ai.system_prompt", attrs.system_prompt) do
      socket
      |> assign(:settings_editor_ai_draft, %{})
      |> assign(:offline_mode, attrs.offline_mode)
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def reset_ai_prompt(socket, reload, append_output) do
    case put_global_setting("ai.system_prompt", "") do
      :ok ->
        socket
        |> assign(:settings_editor_ai_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def save_publishing(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.set_publishing_preferences(project_id, publishing_attrs(socket.assigns)) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_publishing_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Publishing"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def clear_publishing(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.set_publishing_preferences(project_id, %{}) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_publishing_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Publishing"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def update_new_category(socket, name, reload) do
    socket
    |> assign(:settings_editor_new_category, to_string(name || ""))
    |> reload.(socket.assigns.workbench)
  end

  def add_category(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    name = socket.assigns[:settings_editor_new_category] |> to_string() |> String.trim()

    cond do
      name == "" ->
        socket
        |> append_output.(translated("Categories"), translated("Category name is required"), nil, "error")
        |> reload.(socket.assigns.workbench)

      true ->
        case Metadata.add_category(project_id, name) do
          {:ok, _metadata} ->
            socket
            |> assign(:settings_editor_new_category, "")
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Categories"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def reset_categories(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    result =
      Enum.reduce_while(category_names(project_metadata(socket.assigns)), :ok, fn category, _acc ->
        if MapSet.member?(@protected_categories, category) do
          {:cont, :ok}
        else
          case Metadata.remove_category(project_id, category) do
            {:ok, _metadata} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)

    with :ok <- result,
         :ok <- ensure_default_categories(project_id),
         :ok <- reset_default_category_settings(project_id) do
      socket
      |> assign(:settings_editor_new_category, "")
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(translated("Categories"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def toggle_mcp_agent(socket, agent, reload, append_output) do
    case find_mcp_agent(agent) do
      %{id: agent_id, supported?: true} = config ->
        if mcp_configured?(config) do
          {:ok, _payload} = AgentConfig.remove_from_config(agent_id)
          reload.(socket, socket.assigns.workbench)
        else
          install_root = Application.app_dir(:bds)
          {:ok, _payload} = AgentConfig.add_to_config(agent_id, install_root: install_root)
          reload.(socket, socket.assigns.workbench)
        end

      _other ->
        socket
        |> append_output.(translated("MCP"), translated("This MCP agent is not supported in the rewrite yet"), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def save_category(socket, params, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    category = Map.get(params, "category", "")

    settings = %{
      title: blank_to_nil(Map.get(params, "title")),
      render_in_lists: truthy?(Map.get(params, "render_in_lists")),
      show_title: truthy?(Map.get(params, "show_title")),
      post_template_slug: blank_to_nil(Map.get(params, "post_template_slug")),
      list_template_slug: blank_to_nil(Map.get(params, "list_template_slug"))
    }

    case Metadata.update_category_settings(project_id, category, settings) do
      {:ok, _metadata} -> reload.(socket, socket.assigns.workbench)
      {:error, reason} ->
        socket
        |> append_output.(translated("Categories"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def remove_category(socket, category, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    cond do
      MapSet.member?(@protected_categories, category) ->
        socket
        |> append_output.(translated("Categories"), translated("Protected categories cannot be removed"), nil, "error")
        |> reload.(socket.assigns.workbench)

      true ->
        case Metadata.remove_category(project_id, category) do
          {:ok, _metadata} -> reload.(socket, socket.assigns.workbench)
          {:error, reason} ->
            socket
            |> append_output.(translated("Categories"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def select_style_theme(socket, theme, reload) do
    socket
    |> assign(:style_editor_theme, to_string(theme || "default"))
    |> reload.(socket.assigns.workbench)
  end

  def change_style_preview_mode(socket, mode, reload) do
    socket
    |> assign(:style_editor_preview_mode, to_string(mode || "auto"))
    |> reload.(socket.assigns.workbench)
  end

  def apply_style_theme(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    theme = socket.assigns[:style_editor_theme] || current_theme(socket.assigns)

    case Metadata.update_project_metadata(project_id, %{pico_theme: theme}) do
      {:ok, _metadata} -> reload.(socket, socket.assigns.workbench)
      {:error, reason} ->
        socket
        |> append_output.(translated("Style"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def build_settings(%{projects: %{active_project_id: nil}}), do: nil

  def build_settings(assigns) do
    metadata = project_metadata(assigns)
    project_form = Map.merge(project_form(metadata), Map.get(assigns, :settings_editor_project_draft, %{}))
    editor_form = Map.merge(editor_form(), Map.get(assigns, :settings_editor_editor_draft, %{}))
    ai_form = Map.merge(ai_form(assigns), Map.get(assigns, :settings_editor_ai_draft, %{}))
    publishing_form = Map.merge(publishing_form(metadata), Map.get(assigns, :settings_editor_publishing_draft, %{}))
    query = Map.get(assigns, :settings_editor_search, "")
    selected_section = current_settings_section(assigns)
    visible_sections = visible_settings_sections(query)

    %{
      search_query: query,
      selected_section: selected_section,
      active_sections: visible_sections,
      project: project_form,
      editor: editor_form,
      categories: category_rows(metadata),
      ai: ai_form,
      technology: technology_form(project_form),
      publishing: publishing_form,
      mcp: mcp_rows(),
      new_category: Map.get(assigns, :settings_editor_new_category, ""),
      project_data_path: Map.get(assigns.current_project || %{}, :data_path) || "",
      project_data_default_path: Map.get(assigns.current_project || %{}, :project_path) || "",
      template_options: template_options(assigns.projects.active_project_id),
      online_endpoint_models: endpoint_model_options(assigns, :online),
      offline_endpoint_models: endpoint_model_options(assigns, :airplane),
      project_visible?: section_matches?(query, ~w(project name description url language author category posts bookmarklet)),
      editor_visible?: section_matches?(query, ~w(editor mode markdown preview diff wrap unchanged)),
      content_visible?: section_matches?(query, ~w(content categories templates lists blogmark)),
      ai_visible?: section_matches?(query, ~w(ai assistant model prompt airplane offline online endpoint url api key chat title image)),
      technology_visible?: section_matches?(query, ~w(technology runtime semantic similarity embedding scripting)),
      publishing_visible?: section_matches?(query, ~w(publishing ssh scp rsync host user remote path)),
      mcp_visible?: section_matches?(query, ~w(mcp claude copilot gemini opencode mistral codex agent server)),
      data_visible?: section_matches?(query, ~w(data rebuild maintenance folder filesystem)),
      supported_languages: @supported_languages,
      protected_categories: @protected_categories
    }
  end

  def build_style(%{projects: %{active_project_id: nil}}), do: nil

  def build_style(assigns) do
    selected_theme = Map.get(assigns, :style_editor_theme) || current_theme(assigns)
    preview_mode = Map.get(assigns, :style_editor_preview_mode, "auto")

    %{
      themes: Enum.map(@themes, &style_theme/1),
      selected_theme: selected_theme,
      applied_theme: current_theme(assigns),
      preview_mode: preview_mode,
      preview_url: "http://127.0.0.1:4123/__style-preview?theme=#{selected_theme}&mode=#{preview_mode}"
    }
  end

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  def protected_category?(category), do: MapSet.member?(@protected_categories, category)

  def theme_display_name(theme) do
    theme
    |> to_string()
    |> String.replace("-", " ")
    |> String.capitalize()
  end

  defp project_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_project_draft, %{})

    %{
      name: blank_to_nil(Map.get(draft, "name")),
      description: blank_to_nil(Map.get(draft, "description")),
      public_url: blank_to_nil(Map.get(draft, "public_url")),
      main_language: blank_to_nil(Map.get(draft, "main_language")),
      default_author: blank_to_nil(Map.get(draft, "default_author")),
      max_posts_per_page: parse_integer(Map.get(draft, "max_posts_per_page"), 50),
      blogmark_category: blank_to_nil(Map.get(draft, "blogmark_category")),
      blog_languages: Map.get(draft, "blog_languages", []),
      semantic_similarity_enabled: truthy?(Map.get(draft, "semantic_similarity_enabled"))
    }
  end

  defp editor_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_editor_draft, %{})

    %{
      default_mode: Map.get(draft, "default_mode", "markdown"),
      diff_view_style: Map.get(draft, "diff_view_style", "inline"),
      wrap_long_lines: truthy?(Map.get(draft, "wrap_long_lines")),
      hide_unchanged_regions: truthy?(Map.get(draft, "hide_unchanged_regions"))
    }
  end

  defp publishing_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_publishing_draft, %{})

    %{
      ssh_host: blank_to_nil(Map.get(draft, "ssh_host")),
      ssh_user: blank_to_nil(Map.get(draft, "ssh_user")),
      ssh_remote_path: blank_to_nil(Map.get(draft, "ssh_remote_path")),
      ssh_mode: Map.get(draft, "ssh_mode", "scp")
    }
  end

  defp ai_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_ai_draft, %{})

    %{
      online_url: blank_to_nil(Map.get(draft, "online_url")),
      online_api_key: blank_to_nil(Map.get(draft, "online_api_key")),
      online_chat_model: blank_to_nil(Map.get(draft, "online_chat_model")),
      online_title_model: blank_to_nil(Map.get(draft, "online_title_model")),
      online_image_analysis_model: blank_to_nil(Map.get(draft, "online_image_analysis_model")),
      offline_url: blank_to_nil(Map.get(draft, "offline_url")),
      offline_api_key: blank_to_nil(Map.get(draft, "offline_api_key")),
      offline_mode: truthy?(Map.get(draft, "offline_mode")),
      offline_chat_model: blank_to_nil(Map.get(draft, "offline_chat_model")),
      offline_title_model: blank_to_nil(Map.get(draft, "offline_title_model")),
      offline_image_analysis_model: blank_to_nil(Map.get(draft, "offline_image_analysis_model")),
      system_prompt: Map.get(draft, "system_prompt", "")
    }
  end

  defp project_metadata(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} -> metadata
    end
  end

  defp project_form(metadata) do
    %{
      "name" => Map.get(metadata, :name, ""),
      "description" => Map.get(metadata, :description, ""),
      "public_url" => Map.get(metadata, :public_url, ""),
      "main_language" => Map.get(metadata, :main_language) || "en",
      "default_author" => Map.get(metadata, :default_author, ""),
      "max_posts_per_page" => Integer.to_string(Map.get(metadata, :max_posts_per_page, 50)),
      "blogmark_category" => Map.get(metadata, :blogmark_category) || List.first(Map.get(metadata, :categories, [])) || "article",
      "blog_languages" => Map.get(metadata, :blog_languages, []),
      "semantic_similarity_enabled" => Map.get(metadata, :semantic_similarity_enabled, false)
    }
  end

  defp editor_form do
    %{
      "default_mode" => get_global_setting("ui.preferred_editor_mode") || "markdown",
      "diff_view_style" => get_global_setting("ui.git_diff_view_style") || "inline",
      "wrap_long_lines" => get_global_setting("ui.git_diff_word_wrap") == "true",
      "hide_unchanged_regions" => get_global_setting("ui.git_diff_hide_unchanged_regions") == "true"
    }
  end

  defp publishing_form(metadata) do
    prefs = Map.get(metadata, :publishing_preferences, %{})

    %{
      "ssh_host" => Map.get(prefs, "ssh_host", ""),
      "ssh_user" => Map.get(prefs, "ssh_user", ""),
      "ssh_remote_path" => Map.get(prefs, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(prefs, "ssh_mode", "scp")
    }
  end

  defp ai_form(assigns) do
    {:ok, online_endpoint} = AI.get_endpoint(:online)
    {:ok, airplane_endpoint} = AI.get_endpoint(:airplane)

    %{
      "online_url" => Map.get(online_endpoint || %{}, :url, ""),
      "online_api_key" => Map.get(online_endpoint || %{}, :api_key, ""),
      "online_chat_model" => get_model_preference(:chat) || Map.get(online_endpoint || %{}, :model, ""),
      "online_title_model" => get_model_preference(:title),
      "online_image_analysis_model" => get_model_preference(:image_analysis),
      "offline_url" => Map.get(airplane_endpoint || %{}, :url, ""),
      "offline_api_key" => Map.get(airplane_endpoint || %{}, :api_key, ""),
      "offline_mode" => Map.get(assigns, :offline_mode, AI.airplane_mode?(true)),
      "offline_chat_model" => get_model_preference(:airplane_chat) || Map.get(airplane_endpoint || %{}, :model, ""),
      "offline_title_model" => get_model_preference(:airplane_title),
      "offline_image_analysis_model" => get_model_preference(:airplane_image_analysis),
      "system_prompt" => get_global_setting("ai.system_prompt") || ""
    }
  end

  defp technology_form(project_form) do
    %{
      "semantic_similarity_enabled" => Map.get(project_form, "semantic_similarity_enabled", false)
    }
  end

  defp current_theme(assigns) do
    assigns
    |> project_metadata()
    |> Map.get(:pico_theme)
    |> case do
      nil -> "default"
      "" -> "default"
      theme -> theme
    end
  end

  defp category_rows(metadata) do
    categories = Map.get(metadata, :categories, [])
    settings = Map.get(metadata, :category_settings, %{})

    Enum.map(categories, fn category ->
      category_settings = Map.get(settings, category, %{})

      %{
        name: category,
        title: Map.get(category_settings, "title") || category,
        render_in_lists: Map.get(category_settings, "render_in_lists", true),
        show_title: Map.get(category_settings, "show_title", true),
        post_template_slug: Map.get(category_settings, "post_template_slug", ""),
        list_template_slug: Map.get(category_settings, "list_template_slug", ""),
        protected?: protected_category?(category)
      }
    end)
  end

  defp category_names(metadata), do: Map.get(metadata, :categories, [])

  defp normalize_project_params(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "public_url" => Map.get(params, "public_url", ""),
      "main_language" => Map.get(params, "main_language", "en"),
      "default_author" => Map.get(params, "default_author", ""),
      "max_posts_per_page" => Map.get(params, "max_posts_per_page", "50"),
      "blogmark_category" => Map.get(params, "blogmark_category", "article"),
      "blog_languages" => List.wrap(Map.get(params, "blog_languages", [])),
      "semantic_similarity_enabled" => truthy?(Map.get(params, "semantic_similarity_enabled"))
    }
  end

  defp normalize_editor_params(params) do
    %{
      "default_mode" => Map.get(params, "default_mode", "markdown"),
      "diff_view_style" => Map.get(params, "diff_view_style", "inline"),
      "wrap_long_lines" => truthy?(Map.get(params, "wrap_long_lines")),
      "hide_unchanged_regions" => truthy?(Map.get(params, "hide_unchanged_regions"))
    }
  end

  defp normalize_publishing_params(params) do
    %{
      "ssh_host" => Map.get(params, "ssh_host", ""),
      "ssh_user" => Map.get(params, "ssh_user", ""),
      "ssh_remote_path" => Map.get(params, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(params, "ssh_mode", "scp")
    }
  end

  defp normalize_ai_params(params) do
    %{
      "online_url" => Map.get(params, "online_url", ""),
      "online_api_key" => Map.get(params, "online_api_key", ""),
      "online_chat_model" => Map.get(params, "online_chat_model", ""),
      "online_title_model" => Map.get(params, "online_title_model", ""),
      "online_image_analysis_model" => Map.get(params, "online_image_analysis_model", ""),
      "offline_url" => Map.get(params, "offline_url", ""),
      "offline_api_key" => Map.get(params, "offline_api_key", ""),
      "offline_mode" => truthy?(Map.get(params, "offline_mode")),
      "offline_chat_model" => Map.get(params, "offline_chat_model", ""),
      "offline_title_model" => Map.get(params, "offline_title_model", ""),
      "offline_image_analysis_model" => Map.get(params, "offline_image_analysis_model", ""),
      "system_prompt" => Map.get(params, "system_prompt", "")
    }
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
        "project" -> section_matches?(query, ~w(project name description data url language author bookmarklet))
        "editor" -> section_matches?(query, ~w(editor mode markdown preview diff wrap unchanged))
        "content" -> section_matches?(query, ~w(content categories templates lists blogmark))
        "ai" -> section_matches?(query, ~w(ai assistant model prompt airplane offline online endpoint url api key chat title image))
        "technology" -> section_matches?(query, ~w(technology semantic similarity runtime scripting embedding))
        "publishing" -> section_matches?(query, ~w(publishing ssh scp rsync host user remote path))
        "data" -> section_matches?(query, ~w(data rebuild maintenance links thumbnails filesystem))
        "mcp" -> section_matches?(query, ~w(mcp claude copilot gemini opencode mistral codex agent server))
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

  defp mcp_rows do
    Enum.map(@mcp_agents, fn agent ->
      %{
        id: agent.id,
        label: agent.label,
        supported?: agent.supported?,
        configured?: mcp_configured?(agent),
        config_path: mcp_config_path(agent)
      }
    end)
  end

  defp find_mcp_agent(agent) do
    normalized =
      agent
      |> to_string()
      |> String.to_existing_atom()

    Enum.find(@mcp_agents, &(&1.id == normalized))
  rescue
    _error -> nil
  end

  defp mcp_configured?(%{supported?: false}), do: false

  defp mcp_configured?(%{id: agent_id}) do
    path = AgentConfig.config_path(agent_id, System.user_home!())

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> mcp_server_present?(agent_id)
    else
      false
    end
  rescue
    _error -> false
  end

  defp mcp_config_path(%{supported?: false}), do: nil
  defp mcp_config_path(%{id: agent_id}), do: AgentConfig.config_path(agent_id, System.user_home!())

  defp mcp_server_present?(config, :github_copilot) do
    config
    |> Map.get("servers", %{})
    |> Map.has_key?("bDS")
  end

  defp mcp_server_present?(config, _agent_id) do
    config
    |> Map.get("mcpServers", %{})
    |> Map.has_key?("bDS")
  end

  defp get_model_preference(key) do
    case AI.get_model_preference(key) do
      {:ok, value} -> value || ""
      _other -> ""
    end
  end

  defp maybe_put_model_preference(_key, nil), do: :ok
  defp maybe_put_model_preference(_key, ""), do: :ok
  defp maybe_put_model_preference(key, value), do: AI.put_model_preference(key, value)

  defp put_endpoint_preferences(kind, url, api_key, primary_model) do
    if Enum.all?([url, api_key, primary_model], &(blank_to_nil(&1) == nil)) do
      AI.delete_endpoint(kind)
    else
      AI.put_endpoint(kind, %{url: url, api_key: api_key, model: primary_model}) |> normalize_endpoint_result()
    end
  end

  defp endpoint_model_options(assigns, endpoint_key) do
    assigns
    |> Map.get(:settings_editor_endpoint_models, %{})
    |> Map.get(endpoint_key, [])
  end

  defp endpoint_refresh_attrs(:online, attrs) do
    endpoint_refresh_attrs(attrs.online_url, attrs.online_api_key)
  end

  defp endpoint_refresh_attrs(:airplane, attrs) do
    endpoint_refresh_attrs(attrs.offline_url, attrs.offline_api_key)
  end

  defp endpoint_refresh_attrs(url, api_key) do
    case blank_to_nil(url) do
      nil -> {:error, :endpoint_not_configured}
      loaded_url -> {:ok, %{url: loaded_url, api_key: api_key}}
    end
  end

  defp normalize_endpoint_result({:ok, _endpoint}), do: :ok
  defp normalize_endpoint_result({:error, reason}), do: {:error, reason}

  defp ensure_default_categories(project_id) do
    Enum.reduce_while(Map.keys(@default_category_settings), :ok, fn category, _acc ->
      case Metadata.add_category(project_id, category) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reset_default_category_settings(project_id) do
    Enum.reduce_while(@default_category_settings, :ok, fn {category, settings}, _acc ->
      case Metadata.update_category_settings(project_id, category, settings) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp get_global_setting(key) do
    case Repo.get(Setting, key) do
      %Setting{value: value} -> value
      _other -> nil
    end
  end

  defp put_global_setting(key, value) do
    setting = Repo.get(Setting, key) || %Setting{}

    setting
    |> Setting.changeset(%{key: key, value: to_string(value || ""), updated_at: Persistence.now_ms()})
    |> Repo.insert_or_update()
    |> case do
      {:ok, _setting} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp section_matches?("", _keywords), do: true
  defp section_matches?(query, keywords), do: Enum.any?(keywords, &String.contains?(&1, String.downcase(query)))

  defp style_theme(name) do
    %{
      name: name,
      accent_color: "#4f46e5",
      light_bg_color: "#f8fafc",
      dark_bg_color: "#0f172a"
    }
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
  defp boolean_string(true), do: "true"
  defp boolean_string(false), do: "false"
  defp parse_integer(nil, fallback), do: fallback
  defp parse_integer(value, _fallback) when is_integer(value), do: value
  defp parse_integer(value, fallback) do
    case Integer.parse(to_string(value)) do
      {parsed, _rest} -> parsed
      :error -> fallback
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
