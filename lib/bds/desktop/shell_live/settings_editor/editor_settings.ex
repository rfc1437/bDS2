defmodule BDS.Desktop.ShellLive.SettingsEditor.EditorSettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Settings
  use Gettext, backend: BDS.Gettext

  @spec editor_form() :: term()
  def editor_form do
    %{
      "default_mode" => get_global_setting("ui.preferred_editor_mode") || "markdown",
      "diff_view_style" => get_global_setting("ui.git_diff_view_style") || "inline",
      "wrap_long_lines" => get_global_setting("ui.git_diff_word_wrap") == "true",
      "hide_unchanged_regions" =>
        get_global_setting("ui.git_diff_hide_unchanged_regions") == "true"
    }
  end

  @spec update_editor_draft(term(), term(), term()) :: term()
  def update_editor_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_editor_draft, normalize_editor_params(params))
    |> reload.(socket.assigns.workbench)
  end

  @spec save_editor(term(), term(), term()) :: term()
  def save_editor(socket, reload, append_output) do
    attrs = editor_attrs(socket.assigns)

    with :ok <- put_global_setting("ui.preferred_editor_mode", attrs.default_mode),
         :ok <- put_global_setting("ui.git_diff_view_style", attrs.diff_view_style),
         :ok <- put_global_setting("ui.git_diff_word_wrap", boolean_string(attrs.wrap_long_lines)),
         :ok <-
           put_global_setting(
             "ui.git_diff_hide_unchanged_regions",
             boolean_string(attrs.hide_unchanged_regions)
           ) do
      socket
      |> assign(:settings_editor_editor_draft, %{})
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Editor Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec get_global_setting(term()) :: term()
  def get_global_setting(key) do
    Settings.get_global_setting(key)
  end

  @spec put_global_setting(term(), term()) :: term()
  def put_global_setting(key, value) do
    Settings.put_global_setting(key, value)
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

  defp normalize_editor_params(params) do
    %{
      "default_mode" => Map.get(params, "default_mode", "markdown"),
      "diff_view_style" => Map.get(params, "diff_view_style", "inline"),
      "wrap_long_lines" => truthy?(Map.get(params, "wrap_long_lines")),
      "hide_unchanged_regions" => truthy?(Map.get(params, "hide_unchanged_regions"))
    }
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
  defp boolean_string(true), do: "true"
  defp boolean_string(false), do: "false"
end
