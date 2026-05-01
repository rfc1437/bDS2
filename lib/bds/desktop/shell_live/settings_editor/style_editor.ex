defmodule BDS.Desktop.ShellLive.SettingsEditor.StyleEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  alias BDS.Desktop.ShellData

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
      {:ok, _metadata} ->
        reload.(socket, socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Style"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def theme_display_name(theme) do
    theme
    |> to_string()
    |> String.replace("-", " ")
    |> String.capitalize()
  end

  def current_theme(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} ->
        case Map.get(metadata, :pico_theme) do
          nil -> "default"
          "" -> "default"
          theme -> theme
        end
    end
  end

  defp style_theme(name) do
    %{
      name: name,
      accent_color: "#4f46e5",
      light_bg_color: "#f8fafc",
      dark_bg_color: "#0f172a"
    }
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
