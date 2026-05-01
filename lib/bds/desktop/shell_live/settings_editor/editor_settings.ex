defmodule BDS.Desktop.ShellLive.SettingsEditor.EditorSettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Persistence
  alias BDS.Repo
  alias BDS.Settings.Setting
  alias BDS.Desktop.ShellData

  def editor_form do
    %{
      "default_mode" => get_global_setting("ui.preferred_editor_mode") || "markdown",
      "diff_view_style" => get_global_setting("ui.git_diff_view_style") || "inline",
      "wrap_long_lines" => get_global_setting("ui.git_diff_word_wrap") == "true",
      "hide_unchanged_regions" => get_global_setting("ui.git_diff_hide_unchanged_regions") == "true"
    }
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
        |> append_output.(translated("Editor Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def get_global_setting(key) do
    case Repo.get(Setting, key) do
      %Setting{value: value} -> value
      _other -> nil
    end
  end

  def put_global_setting(key, value) do
    setting = Repo.get(Setting, key) || %Setting{}

    setting
    |> Setting.changeset(%{key: key, value: to_string(value || ""), updated_at: Persistence.now_ms()})
    |> Repo.insert_or_update()
    |> case do
      {:ok, _setting} -> :ok
      {:error, reason} -> {:error, reason}
    end
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

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end
