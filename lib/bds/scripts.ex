defmodule BDS.Scripts do
  @moduledoc false

  import Ecto.Query

  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Slug

  def create_script(attrs) do
    now = System.system_time(:second)
    project_id = attr(attrs, :project_id)
    title = attr(attrs, :title) || ""
    kind = attr(attrs, :kind)

    %Script{}
    |> Script.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      slug: unique_slug(project_id, Slug.slugify(title), "script"),
      title: title,
      kind: kind,
      entrypoint: attr(attrs, :entrypoint) || default_entrypoint(kind),
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

  defp default_entrypoint(:macro), do: "render"
  defp default_entrypoint(_kind), do: "main"

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
    not Repo.exists?(from script in Script, where: script.project_id == ^project_id and script.slug == ^slug)
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
