defmodule BDS.Projects do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Slug

  def list_projects do
    Repo.all(from project in Project, order_by: [asc: project.created_at])
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def create_project(attrs) do
    now = System.system_time(:second)
    name = attr(attrs, :name) || ""
    slug = unique_slug(attr(attrs, :slug) || Slug.slugify(name))

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
    |> Repo.insert()
  end

  def set_active_project(project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      project ->
        now = System.system_time(:second)

        Multi.new()
        |> Multi.update_all(:clear_previous, from(p in Project, where: p.is_active == true),
          set: [is_active: false, updated_at: now]
        )
        |> Multi.update(:activate, Project.changeset(project, %{is_active: true, updated_at: now}))
        |> Repo.transaction()
        |> case do
          {:ok, %{activate: active_project}} -> {:ok, active_project}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
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

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
