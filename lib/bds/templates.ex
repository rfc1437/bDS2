defmodule BDS.Templates do
  @moduledoc false

  import Ecto.Query

  alias BDS.Repo
  alias BDS.Slug
  alias BDS.Templates.Template

  def create_template(attrs) do
    now = System.system_time(:second)
    project_id = attr(attrs, :project_id)
    title = attr(attrs, :title) || ""

    %Template{}
    |> Template.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      slug: unique_slug(project_id, Slug.slugify(title), "template"),
      title: title,
      kind: attr(attrs, :kind),
      enabled: true,
      version: 1,
      file_path: "",
      status: :draft,
      content: attr(attrs, :content),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
  end

  defp unique_slug(project_id, base_slug, fallback) do
    normalized = if base_slug in [nil, ""], do: fallback, else: base_slug

    if slug_available?(project_id, normalized) do
      normalized
    else
      find_unique_slug(project_id, normalized, 2)
    end
  end

  defp find_unique_slug(project_id, base_slug, suffix) do
    candidate = "#{base_slug}-#{suffix}"

    if slug_available?(project_id, candidate) do
      candidate
    else
      find_unique_slug(project_id, base_slug, suffix + 1)
    end
  end

  defp slug_available?(project_id, slug) do
    not Repo.exists?(from template in Template, where: template.project_id == ^project_id and template.slug == ^slug)
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
