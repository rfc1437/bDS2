defmodule BDS.Desktop.ShellLive.SettingsEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  alias BDS.Desktop.ShellData

  embed_templates "settings_editor_html/*"

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
    publishing_form = Map.merge(publishing_form(metadata), Map.get(assigns, :settings_editor_publishing_draft, %{}))
    query = Map.get(assigns, :settings_editor_search, "")

    %{
      search_query: query,
      project: project_form,
      categories: category_rows(metadata),
      publishing: publishing_form,
      new_category: Map.get(assigns, :settings_editor_new_category, ""),
      project_visible?: section_matches?(query, ~w(project name description url language author category posts bookmarklet)),
      content_visible?: section_matches?(query, ~w(content categories templates lists blogmark)),
      publishing_visible?: section_matches?(query, ~w(publishing ssh scp rsync host user remote path)),
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

  defp publishing_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_publishing_draft, %{})

    %{
      ssh_host: blank_to_nil(Map.get(draft, "ssh_host")),
      ssh_user: blank_to_nil(Map.get(draft, "ssh_user")),
      ssh_remote_path: blank_to_nil(Map.get(draft, "ssh_remote_path")),
      ssh_mode: Map.get(draft, "ssh_mode", "scp")
    }
  end

  defp project_metadata(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} -> metadata
      _other -> %{}
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

  defp publishing_form(metadata) do
    prefs = Map.get(metadata, :publishing_preferences, %{})

    %{
      "ssh_host" => Map.get(prefs, "ssh_host", ""),
      "ssh_user" => Map.get(prefs, "ssh_user", ""),
      "ssh_remote_path" => Map.get(prefs, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(prefs, "ssh_mode", "scp")
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

  defp normalize_publishing_params(params) do
    %{
      "ssh_host" => Map.get(params, "ssh_host", ""),
      "ssh_user" => Map.get(params, "ssh_user", ""),
      "ssh_remote_path" => Map.get(params, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(params, "ssh_mode", "scp")
    }
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