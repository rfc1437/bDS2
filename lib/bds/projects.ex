defmodule BDS.Projects do
  @moduledoc false

  import Ecto.Query

  alias BDS.Metadata
  alias BDS.Persistence
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Slug
  alias BDS.Templates

  @default_project_id "default"
  @default_project_name "My Blog"

  @typedoc "An attribute map that may use atom or string keys."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @typedoc "Summary map returned for the shell projects panel."
  @type project_summary :: %{
          id: String.t(),
          name: String.t(),
          slug: String.t(),
          data_path: String.t() | nil,
          is_active: boolean()
        }

  @typedoc "Snapshot returned to the desktop shell."
  @type shell_snapshot :: %{
          active_project_id: String.t() | nil,
          projects: [project_summary()]
        }

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Repo.all(from project in Project, order_by: [asc: project.created_at])
  end

  @spec get_active_project() :: Project.t() | nil
  def get_active_project do
    Repo.one(from project in Project, where: project.is_active == true, limit: 1)
  end

  @spec shell_snapshot() :: shell_snapshot()
  def shell_snapshot do
    _ = ensure_default_project()
    projects = list_projects()
    active_project = Enum.find(projects, & &1.is_active)

    %{
      active_project_id: active_project && active_project.id,
      projects: Enum.map(projects, &project_summary/1)
    }
  end

  @spec get_project(String.t()) :: Project.t() | nil
  def get_project(id), do: Repo.get(Project, id)

  @spec get_project!(String.t()) :: Project.t()
  def get_project!(id), do: Repo.get!(Project, id)

  @spec ensure_default_project() :: {:ok, Project.t()} | {:error, term()}
  def ensure_default_project do
    case Repo.get(Project, @default_project_id) do
      %Project{} = project ->
        {:ok, project}

      nil ->
        now = Persistence.now_ms()
        is_active = not Repo.exists?(from project in Project, where: project.is_active == true)

        Repo.transaction(fn ->
          project =
            %Project{}
            |> Project.changeset(%{
              id: @default_project_id,
              name: @default_project_name,
              slug: unique_slug(Slug.slugify(@default_project_name)),
              description: nil,
              data_path: nil,
              created_at: now,
              updated_at: now,
              is_active: is_active
            })
            |> Repo.insert!()

          project
        end)
        |> case do
          {:ok, project} -> rebuild_project_templates(project)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec project_data_dir(Project.t()) :: String.t()
  def project_data_dir(%Project{} = project) do
    project.data_path || Path.expand("../../priv/data/projects/#{project.id}", __DIR__)
  end

  @spec project_cache_dir(Project.t() | String.t()) :: String.t()
  def project_cache_dir(%Project{} = project), do: project_cache_dir(project.id)

  def project_cache_dir(project_id) when is_binary(project_id) do
    Path.join([project_cache_root(), "projects", project_id])
  end

  @spec create_project(attrs()) :: {:ok, Project.t()} | {:error, term()}
  def create_project(attrs) do
    now = Persistence.now_ms()
    name = attr(attrs, :name) || ""
    slug = unique_slug(attr(attrs, :slug) || Slug.slugify(name))

    Repo.transaction(fn ->
      project =
        %Project{}
        |> Project.changeset(%{
          id: Ecto.UUID.generate(),
          name: name,
          slug: slug,
          description: attr(attrs, :description),
          data_path: attr(attrs, :data_path),
          created_at: now,
          updated_at: now,
          is_active: false
        })
        |> Repo.insert!()

      project
    end)
    |> case do
      {:ok, project} ->
        with {:ok, project} <- rebuild_project_templates(project) do
          sync_filesystem_metadata(project)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec set_active_project(String.t()) :: {:ok, Project.t()} | {:error, :not_found | term()}
  def set_active_project(project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      project ->
        now = Persistence.now_ms()

        Repo.transaction(fn ->
          Repo.update_all(
            from(p in Project, where: p.is_active == true),
            set: [is_active: false, updated_at: now]
          )

          project
          |> Project.changeset(%{is_active: true, updated_at: now})
          |> Repo.update!()
        end)
        |> case do
          {:ok, active_project} -> {:ok, active_project}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec delete_project(String.t()) ::
          {:ok, Project.t()}
          | {:error,
             :not_found | :cannot_delete_default_project | :cannot_delete_active_project | term()}
  def delete_project(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      %Project{id: @default_project_id} ->
        {:error, :cannot_delete_default_project}

      %Project{is_active: true} ->
        {:error, :cannot_delete_active_project}

      %Project{} = project ->
        internal_dir = if is_nil(project.data_path), do: project_data_dir(project), else: nil

        cleanup_dirs =
          [internal_dir, project_cache_dir(project)] |> Enum.filter(&is_binary/1) |> Enum.uniq()

        Repo.transaction(fn ->
          case Repo.delete(project) do
            {:ok, deleted} -> deleted
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, deleted_project} ->
            Enum.each(cleanup_dirs, fn dir ->
              _ = File.rm_rf(dir)
            end)

            {:ok, deleted_project}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp project_summary(%Project{} = project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      data_path: project.data_path,
      is_active: project.is_active
    }
  end

  defp sync_filesystem_metadata(%Project{data_path: nil} = project), do: {:ok, project}

  defp sync_filesystem_metadata(%Project{} = project) do
    case Metadata.sync_project_metadata_from_filesystem(project.id) do
      {:ok, _metadata} -> {:ok, get_project!(project.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebuild_project_templates(%Project{} = project) do
    with {:ok, _templates} <- Templates.rebuild_templates_from_files(project.id) do
      {:ok, project}
    end
  end

  defp unique_slug(base_slug) do
    normalized = if base_slug in [nil, ""], do: "project", else: base_slug

    if slug_available?(normalized) do
      normalized
    else
      find_unique_slug(normalized, 2)
    end
  end

  defp find_unique_slug(base_slug, suffix) do
    candidate = "#{base_slug}-#{suffix}"

    if slug_available?(candidate) do
      candidate
    else
      find_unique_slug(base_slug, suffix + 1)
    end
  end

  defp slug_available?(slug) do
    not Repo.exists?(from project in Project, where: project.slug == ^slug)
  end

  defp repo_data_dir do
    Application.fetch_env!(:bds, BDS.Repo)
    |> Keyword.fetch!(:database)
    |> Path.expand()
    |> Path.dirname()
  end

  defp project_cache_root do
    case Application.get_env(:bds, :project_cache_root) do
      root when is_binary(root) -> Path.expand(root)
      _other -> repo_data_dir()
    end
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
