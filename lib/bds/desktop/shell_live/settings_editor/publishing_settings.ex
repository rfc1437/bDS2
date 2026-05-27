defmodule BDS.Desktop.ShellLive.SettingsEditor.PublishingSettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  use Gettext, backend: BDS.Gettext

  @spec publishing_form(term()) :: term()
  def publishing_form(metadata) do
    prefs = metadata.publishing_preferences

    %{
      "ssh_host" => Map.get(prefs, "ssh_host", ""),
      "ssh_user" => Map.get(prefs, "ssh_user", ""),
      "ssh_remote_path" => Map.get(prefs, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(prefs, "ssh_mode", "scp")
    }
  end

  @spec update_publishing_draft(term(), term(), term()) :: term()
  def update_publishing_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_publishing_draft, normalize_publishing_params(params))
    |> reload.(socket.assigns.workbench)
  end

  @spec save_publishing(term(), term(), term()) :: term()
  def save_publishing(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.set_publishing_preferences(project_id, publishing_attrs(socket.assigns)) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_publishing_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Publishing"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec clear_publishing(term(), term(), term()) :: term()
  def clear_publishing(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    case Metadata.set_publishing_preferences(project_id, %{}) do
      {:ok, _metadata} ->
        socket
        |> assign(:settings_editor_publishing_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Publishing"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
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

  defp normalize_publishing_params(params) do
    %{
      "ssh_host" => Map.get(params, "ssh_host", ""),
      "ssh_user" => Map.get(params, "ssh_user", ""),
      "ssh_remote_path" => Map.get(params, "ssh_remote_path", ""),
      "ssh_mode" => Map.get(params, "ssh_mode", "scp")
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
