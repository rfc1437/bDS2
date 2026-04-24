defmodule BDS.Scripts do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Slug

  def create_script(attrs) do
    now = Persistence.now_ms()
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

  def publish_script(script_id) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      script ->
        file_path = script_file_path(script.slug)
        full_path = full_file_path(script.project_id, file_path)
        updated_at = Persistence.now_ms()
        content = script.content || ""

        :ok =
          Persistence.atomic_write(
            full_path,
            serialize_script_file(
              %{script | status: :published, file_path: file_path, updated_at: updated_at},
              content
            )
          )

        script
        |> Script.changeset(%{
          status: :published,
          file_path: file_path,
          content: nil,
          updated_at: updated_at
        })
        |> Repo.update()
    end
  end

  def update_script(script_id, attrs) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      script ->
        next_slug =
          if has_attr?(attrs, :slug) do
            unique_slug(script.project_id, Slug.slugify(attr(attrs, :slug)), "script", script.id)
          else
            script.slug
          end

        content_changed? = has_attr?(attrs, :content) and attr(attrs, :content) != script.content
        now = Persistence.now_ms()

        updates =
          %{}
          |> maybe_put(:title, attr(attrs, :title))
          |> maybe_put(:kind, attr(attrs, :kind))
          |> maybe_put(:entrypoint, attr(attrs, :entrypoint))
          |> maybe_put(:enabled, attr(attrs, :enabled))
          |> maybe_put(:content, attr(attrs, :content))
          |> Map.put(:slug, next_slug)
          |> Map.put(:version, script.version + 1)
          |> Map.put(:updated_at, now)
          |> maybe_put(
            :status,
            if(script.status == :published and content_changed?, do: :draft, else: nil)
          )

        script
        |> Script.changeset(updates)
        |> Repo.update()
    end
  end

  def delete_script(script_id) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      script ->
        delete_file_if_present(script.project_id, script.file_path)
        Repo.delete!(script)
        {:ok, :deleted}
    end
  end

  def rebuild_scripts_from_files(project_id) do
    project = Projects.get_project!(project_id)

    scripts =
      project
      |> Projects.project_data_dir()
      |> Path.join("scripts")
      |> list_matching_files("*.lua")
      |> Enum.map(&upsert_script_from_file(project_id, project, &1))

    {:ok, scripts}
  end

  defp default_entrypoint(:macro), do: "render"
  defp default_entrypoint(_kind), do: "main"

  defp unique_slug(project_id, base_slug, fallback, exclude_id \\ nil) do
    normalized = if base_slug in [nil, ""], do: fallback, else: base_slug

    if slug_available?(project_id, normalized, exclude_id) do
      normalized
    else
      find_unique_slug(project_id, normalized, 2, exclude_id)
    end
  end

  defp find_unique_slug(project_id, base_slug, suffix, exclude_id) do
    candidate = "#{base_slug}-#{suffix}"

    if slug_available?(project_id, candidate, exclude_id) do
      candidate
    else
      find_unique_slug(project_id, base_slug, suffix + 1, exclude_id)
    end
  end

  defp slug_available?(project_id, slug, exclude_id) do
    query =
      from script in Script, where: script.project_id == ^project_id and script.slug == ^slug

    scoped_query =
      case exclude_id do
        nil -> query
        _id -> from script in query, where: script.id != ^exclude_id
      end

    not Repo.exists?(scoped_query)
  end

  defp script_file_path(slug), do: Path.join(["scripts", "#{slug}.lua"])

  defp full_file_path(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    Path.join(Projects.project_data_dir(project), relative_path)
  end

  defp serialize_script_file(script, content) do
    Frontmatter.serialize_document(
      [
        {:id, script.id},
        {:slug, script.slug},
        {:title, script.title},
        {:kind, script.kind},
        {:entrypoint, script.entrypoint},
        {:enabled, script.enabled},
        {:version, script.version},
        {:created_at, script.created_at},
        {:updated_at, script.updated_at}
      ],
      content
    )
  end

  defp delete_file_if_present(_project_id, file_path) when file_path in [nil, ""], do: :ok

  defp delete_file_if_present(project_id, file_path) do
    full_path = full_file_path(project_id, file_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_script_from_file(project_id, project, path) do
    contents = File.read!(path)
    {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)
    relative_path = Path.relative_to(path, Projects.project_data_dir(project))
    now = Persistence.now_ms()

    attrs = %{
      id: Map.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      slug: Map.fetch!(fields, "slug"),
      title: Map.get(fields, "title") || "",
      kind: parse_script_kind(Map.fetch!(fields, "kind")),
      entrypoint: Map.get(fields, "entrypoint") || "main",
      enabled: Map.get(fields, "enabled", true),
      version: Map.get(fields, "version", 1),
      file_path: relative_path,
      status: :published,
      content: nil,
      created_at: Map.get(fields, "created_at", now),
      updated_at: Map.get(fields, "updated_at", now)
    }

    script = Repo.get_by(Script, project_id: project_id, slug: attrs.slug) || %Script{}

    script
    |> Script.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp parse_script_kind(kind) when is_atom(kind), do: kind
  defp parse_script_kind("macro"), do: :macro
  defp parse_script_kind("utility"), do: :utility
  defp parse_script_kind("transform"), do: :transform

  defp list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join(dir, pattern)
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
