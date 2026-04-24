defmodule BDS.Desktop.ShellController do
  @moduledoc false

  def index_html do
    BDS.UI.ShellPage.render()
  end

  def task_status_json do
    Jason.encode!(BDS.Tasks.status_snapshot())
  end

  def projects_json do
    Jason.encode!(BDS.Projects.shell_snapshot())
  rescue
    error in [Exqlite.Error] ->
      if String.contains?(Exception.message(error), "no such table: projects") do
        Jason.encode!(default_project_snapshot())
      else
        reraise error, __STACKTRACE__
      end
  end

  def upsert_project_json(payload) when is_map(payload) do
    case normalize_project_request(payload) do
      {:create, attrs} -> create_project_json(attrs)
      {:select, project_id} -> select_project_json(project_id)
      :error -> Jason.encode!(%{status: "error", error: %{message: "Missing project name or project_id"}})
    end
  end

  def choose_project_folder_json(payload \\ %{}) when is_map(payload) do
    prompt = Map.get(payload, "prompt") || Map.get(payload, :prompt) || "Select existing blog folder"

    case folder_picker().choose_directory(prompt) do
      {:ok, path} -> Jason.encode!(project_folder_payload(path))
      :cancel -> Jason.encode!(%{status: "cancel"})
      {:error, error} -> Jason.encode!(%{status: "error", error: normalize_error(error)})
    end
  end

  def command_json(payload) when is_map(payload) do
    action = Map.get(payload, "action") || Map.get(payload, :action)
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}

    case BDS.Desktop.ShellCommands.execute(action, params) do
      {:ok, result} -> Jason.encode!(%{status: "ok", result: result})
      {:error, error} -> Jason.encode!(%{status: "error", error: normalize_error(error)})
    end
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}

  defp normalize_project_request(payload) do
    cond do
      present?(Map.get(payload, "name") || Map.get(payload, :name)) ->
        {:create,
         %{
           name: String.trim(Map.get(payload, "name") || Map.get(payload, :name)),
           description: blank_to_nil(Map.get(payload, "description") || Map.get(payload, :description)),
           data_path: blank_to_nil(Map.get(payload, "data_path") || Map.get(payload, :data_path))
         }}

      present?(Map.get(payload, "project_id") || Map.get(payload, :project_id)) ->
        {:select, Map.get(payload, "project_id") || Map.get(payload, :project_id)}

      true ->
        :error
    end
  end

  defp create_project_json(attrs) do
    with {:ok, project} <- BDS.Projects.create_project(attrs),
         {:ok, active_project} <- BDS.Projects.set_active_project(project.id) do
      Jason.encode!(%{status: "ok", project: project_response(active_project), active_project_id: active_project.id})
    else
      {:error, error} -> Jason.encode!(%{status: "error", error: normalize_error(error)})
    end
  end

  defp select_project_json(project_id) do
    case BDS.Projects.set_active_project(project_id) do
      {:ok, project} ->
        Jason.encode!(%{status: "ok", project: project_response(project), active_project_id: project.id})

      {:error, :not_found} ->
        Jason.encode!(%{status: "error", error: %{message: "Project not found"}})

      {:error, error} ->
        Jason.encode!(%{status: "error", error: normalize_error(error)})
    end
  end

  defp project_response(project) do
    %{id: project.id, name: project.name, slug: project.slug, data_path: project.data_path, is_active: project.is_active}
  end

  defp project_folder_payload(path) do
    normalized_path = Path.expand(path)
    project_metadata = read_project_metadata(normalized_path)
    existing_project = find_project_by_data_path(normalized_path)

    %{
      status: "ok",
      path: normalized_path,
      name: Map.get(project_metadata, "name") || Path.basename(normalized_path),
      description: Map.get(project_metadata, "description"),
      existing_project_id: existing_project && existing_project.id
    }
  end

  defp read_project_metadata(path) do
    project_json_path = Path.join([path, "meta", "project.json"])

    case File.read(project_json_path) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, :enoent} -> %{}
    end
  end

  defp find_project_by_data_path(path) do
    normalized_path = Path.expand(path)

    BDS.Projects.list_projects()
    |> Enum.find(fn project ->
      case project.data_path do
        value when is_binary(value) -> Path.expand(value) == normalized_path
        _other -> false
      end
    end)
  end

  defp folder_picker do
    Application.get_env(:bds, :desktop, [])[:folder_picker] || BDS.Desktop.FolderPicker
  end

  defp default_project_snapshot do
    %{
      active_project_id: "default",
      projects: [
        %{
          id: "default",
          name: "My Blog",
          slug: "my-blog",
          data_path: nil,
          is_active: true
        }
      ]
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_value), do: nil
end
