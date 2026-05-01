defmodule BDS.Scripting.Capabilities.Projects do
  @moduledoc false

  import BDS.Scripting.Capabilities.Crud
  import BDS.Scripting.Capabilities.Util

  alias BDS.Metadata
  alias BDS.Projects, as: ProjectsCtx
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Tags

  def create_project(attrs), do: attrs |> normalize_map() |> ProjectsCtx.create_project() |> unwrap_result()

  def delete_project(project_id), do: boolean_result(ProjectsCtx.delete_project(string_or_nil(project_id)))

  def delete_project_with_data(project_id) do
    case string_or_nil(project_id) && ProjectsCtx.get_project(string_or_nil(project_id)) do
      %Project{} = project ->
        data_dir = ProjectsCtx.project_data_dir(project)

        case ProjectsCtx.delete_project(project.id) do
          {:ok, _deleted_project} ->
            _ = File.rm_rf(data_dir)
            true

          {:error, _reason} ->
            false
        end

      _other ->
        false
    end
  end

  def load_project(project_id) do
    case string_or_nil(project_id) do
      nil -> nil
      id -> ProjectsCtx.get_project(id) |> sanitize_nilable()
    end
  end

  def list_projects do
    ProjectsCtx.list_projects()
    |> Enum.map(&sanitize/1)
  end

  def set_active_project(project_id) do
    project_id
    |> string_or_nil()
    |> then(fn
      nil -> {:error, :not_found}
      id -> ProjectsCtx.set_active_project(id)
    end)
    |> unwrap_result()
  end

  def update_project(project_id, attrs) do
    case string_or_nil(project_id) && ProjectsCtx.get_project(string_or_nil(project_id)) do
      %Project{} = project ->
        attrs = normalize_map(attrs)

        updates = %{
          name: Map.get(attrs, "name", project.name),
          description: Map.get(attrs, "description", project.description),
          data_path: Map.get(attrs, "data_path", project.data_path),
          updated_at: System.system_time(:millisecond),
          is_active: Map.get(attrs, "is_active", project.is_active)
        }

        project
        |> Project.changeset(updates)
        |> Repo.update()
        |> unwrap_result()

      _other ->
        nil
    end
  end

  def load_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    sanitize(metadata)
  end

  def update_project_metadata(project_id, attrs) do
    Metadata.update_project_metadata(project_id, normalize_map(attrs))
    |> unwrap_result()
  end

  def add_category(project_id, name) do
    Metadata.add_category(project_id, string_or_nil(name) || "")
    |> unwrap_result()
  end

  def remove_category(project_id, name) do
    Metadata.remove_category(project_id, string_or_nil(name) || "")
    |> unwrap_result()
  end

  def metadata_categories(project_id) do
    load_metadata(project_id)
    |> Map.get("categories", [])
  end

  def metadata_tags(project_id) do
    project_id
    |> list_tags()
    |> Enum.map(&Map.get(&1, "name"))
  end

  def add_meta_tag(project_id, name) do
    normalized_name = string_or_nil(name) |> to_string() |> String.trim()

    cond do
      normalized_name == "" -> metadata_tags(project_id)
      load_tag_by_name(project_id, normalized_name) -> metadata_tags(project_id)
      true ->
        create_tag(project_id, %{"name" => normalized_name})
        metadata_tags(project_id)
    end
  end

  def remove_meta_tag(project_id, name) do
    case load_tag_by_name(project_id, name) do
      %{"id" => tag_id} ->
        _ = delete_tag(project_id, tag_id)
        metadata_tags(project_id)

      _other ->
        metadata_tags(project_id)
    end
  end

  def publishing_preferences(project_id) do
    load_metadata(project_id)
    |> Map.get("publishing_preferences")
  end

  def set_publishing_preferences(project_id, prefs) do
    project_id
    |> Metadata.set_publishing_preferences(normalize_map(prefs))
    |> unwrap_result()
    |> case do
      nil -> nil
      metadata -> Map.get(metadata, "publishing_preferences")
    end
  end

  def clear_publishing_preferences(project_id) do
    set_publishing_preferences(project_id, %{})
  end

  def sync_meta_on_startup(project_id) do
    _ = Tags.sync_tags_from_posts(project_id)

    %{
      tags: metadata_tags(project_id),
      categories: metadata_categories(project_id),
      project_metadata: load_metadata(project_id)
    }
  end

  def data_paths(project_id) do
    database_path = Repo.config()[:database]
    project_dir = project_path(project_id)

    %{
      database: database_path,
      project: project_dir,
      posts: Path.join(project_dir, "posts"),
      media: Path.join(project_dir, "media")
    }
  end

  def read_project_metadata(folder_path) do
    case project_for_folder(folder_path) do
      nil -> read_project_metadata_file(folder_path)
      project -> load_metadata(project.id)
    end
  end

  def project_for_folder(folder_path) do
    normalized = string_or_nil(folder_path)

    ProjectsCtx.list_projects()
    |> Enum.find(fn project -> ProjectsCtx.project_data_dir(project) == normalized end)
  end

  def read_project_metadata_file(folder_path) do
    path = Path.join([string_or_nil(folder_path) || "", "meta", "project.json"])

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} when is_map(decoded) -> sanitize(decoded)
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end
end
