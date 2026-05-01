defmodule BDS.Desktop.ShellLive.SettingsEditor.ProjectSettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  alias BDS.Desktop.ShellData

  def project_metadata(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} -> metadata
    end
  end

  def project_form(metadata) do
    %{
      "name" => Map.get(metadata, :name, ""),
      "description" => Map.get(metadata, :description, ""),
      "public_url" => Map.get(metadata, :public_url, ""),
      "main_language" => Map.get(metadata, :main_language) || "en",
      "default_author" => Map.get(metadata, :default_author, ""),
      "max_posts_per_page" => Integer.to_string(Map.get(metadata, :max_posts_per_page, 50)),
      "blogmark_category" =>
        Map.get(metadata, :blogmark_category) ||
          List.first(Map.get(metadata, :categories, [])) || "article",
      "blog_languages" => Map.get(metadata, :blog_languages, []),
      "semantic_similarity_enabled" => Map.get(metadata, :semantic_similarity_enabled, false)
    }
  end

  def technology_form(project_form) do
    %{
      "semantic_similarity_enabled" => Map.get(project_form, "semantic_similarity_enabled", false)
    }
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

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
