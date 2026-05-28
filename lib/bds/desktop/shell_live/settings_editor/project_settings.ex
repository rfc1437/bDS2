defmodule BDS.Desktop.ShellLive.SettingsEditor.ProjectSettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  use Gettext, backend: BDS.Gettext

  @spec project_metadata(term()) :: term()
  def project_metadata(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} -> metadata
    end
  end

  @spec project_form(term()) :: term()
  def project_form(metadata) do
    %{
      "name" => metadata.name || "",
      "description" => metadata.description || "",
      "public_url" => metadata.public_url || "",
      "main_language" => metadata.main_language || "en",
      "default_author" => metadata.default_author || "",
      "max_posts_per_page" => Integer.to_string(metadata.max_posts_per_page),
      "image_import_concurrency" => Integer.to_string(metadata.image_import_concurrency),
      "blogmark_category" =>
        metadata.blogmark_category ||
          List.first(metadata.categories) || "article",
      "blog_languages" => metadata.blog_languages,
      "semantic_similarity_enabled" => metadata.semantic_similarity_enabled
    }
  end

  @spec technology_form(term()) :: term()
  def technology_form(project_form) do
    %{
      "semantic_similarity_enabled" => Map.get(project_form, "semantic_similarity_enabled", false)
    }
  end

  @spec update_project_draft(term(), term(), term()) :: term()
  def update_project_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_project_draft, normalize_project_params(params))
    |> reload.(socket.assigns.workbench)
  end

  @spec save_project(term(), term(), term()) :: term()
  def save_project(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.update_project_metadata(project_id, project_attrs(socket.assigns)) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_project_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
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
      image_import_concurrency: parse_integer(Map.get(draft, "image_import_concurrency"), 4),
      blogmark_category: blank_to_nil(Map.get(draft, "blogmark_category")),
      blog_languages: Map.get(draft, "blog_languages", []),
      semantic_similarity_enabled: truthy?(Map.get(draft, "semantic_similarity_enabled"))
    }
  end

  defp normalize_project_params(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "public_url" => Map.get(params, "public_url", ""),
      "main_language" => Map.get(params, "main_language", "en"),
      "default_author" => Map.get(params, "default_author", ""),
      "max_posts_per_page" => Map.get(params, "max_posts_per_page", "50"),
      "image_import_concurrency" => Map.get(params, "image_import_concurrency", "4"),
      "blogmark_category" => Map.get(params, "blogmark_category", "article"),
      "blog_languages" => List.wrap(Map.get(params, "blog_languages", [])),
      "semantic_similarity_enabled" => truthy?(Map.get(params, "semantic_similarity_enabled"))
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
