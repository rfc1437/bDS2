defmodule BDS.Scripts do
  @moduledoc false

  import Ecto.Query
  import BDS.MapUtils, only: [attr: 2, maybe_put: 3]

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.ProgressReporter
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Slug

  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}
  @type script_result :: {:ok, Script.t()} | {:error, Ecto.Changeset.t() | term()}

  @spec create_script(attrs()) :: {:ok, Script.t()} | {:error, Ecto.Changeset.t()}
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

  @spec get_script(String.t()) :: Script.t() | nil
  def get_script(script_id) do
    case Repo.get(Script, script_id) do
      %Script{} = script -> hydrate_script_content(script)
      nil -> nil
    end
  end

  @spec publish_script(String.t()) :: script_result() | {:error, :not_found}
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

  @spec update_script(String.t(), attrs()) :: script_result() | {:error, :not_found}
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

        content_changed? =
          has_attr?(attrs, :content) and attr(attrs, :content) != effective_script_content(script)

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

  @spec delete_script(String.t()) :: {:ok, :deleted} | {:error, :not_found | term()}
  def delete_script(script_id) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      script ->
        case Repo.delete(script) do
          {:ok, deleted_script} ->
            delete_file_if_present(deleted_script.project_id, deleted_script.file_path)
            {:ok, :deleted}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @spec rebuild_scripts_from_files(String.t(), keyword()) :: {:ok, [Script.t()]}
  def rebuild_scripts_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)

    script_paths =
      project
      |> Projects.project_data_dir()
      |> Path.join("scripts")
      |> list_matching_files("*.lua")

    total_files = length(script_paths)
    on_progress = progress_callback(opts)
    :ok = report_rebuild_started(on_progress, total_files, "script files")

    scripts =
      script_paths
      |> Enum.with_index(1)
      |> Enum.map(fn {path, index} ->
        script = upsert_script_from_file(project_id, project, path)
        :ok = report_rebuild_progress(on_progress, index, total_files, "script files")
        script
      end)

    {:ok, scripts}
  end

  @spec sync_script_from_file(String.t()) :: {:ok, Script.t()} | {:error, :not_found}
  def sync_script_from_file(script_id) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      %Script{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Script{} = script ->
        project = Projects.get_project!(script.project_id)
        full_path = Path.join(Projects.project_data_dir(project), script.file_path)

        if File.exists?(full_path) do
          {:ok, upsert_script_from_file(script.project_id, project, full_path)}
        else
          {:error, :not_found}
        end
    end
  end

  @spec sync_published_script_file(String.t()) :: {:ok, Script.t()} | {:error, :not_found}
  def sync_published_script_file(script_id) do
    case Repo.get(Script, script_id) do
      nil ->
        {:error, :not_found}

      %Script{file_path: file_path, status: status} = script
      when file_path not in [nil, ""] and status == :published ->
        full_path = full_file_path(script.project_id, script.file_path)
        body = published_script_body(script)
        :ok = Persistence.atomic_write(full_path, serialize_script_file(script, body))
        {:ok, script}

      %Script{} ->
        {:error, :not_found}
    end
  end

  @spec import_orphan_script_file(String.t(), String.t()) ::
          {:ok, Script.t()} | {:error, :not_found}
  def import_orphan_script_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    if File.exists?(full_path) do
      {:ok, upsert_script_from_file(project_id, project, full_path)}
    else
      {:error, :not_found}
    end
  end

  defp default_entrypoint(:macro), do: "render"
  defp default_entrypoint(_kind), do: "main"

  defp unique_slug(project_id, base_slug, fallback, exclude_id \\ nil) do
    normalized = if base_slug == "", do: fallback, else: base_slug

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
        {"id", script.id},
        {"projectId", script.project_id},
        {"slug", script.slug},
        {"title", script.title},
        {"kind", script.kind},
        {"entrypoint", script.entrypoint},
        {"enabled", script.enabled},
        {"version", script.version},
        {"createdAt", script.created_at},
        {"updatedAt", script.updated_at}
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

  defp published_script_body(%Script{content: content}) when is_binary(content), do: content

  defp published_script_body(script) do
    case File.read(full_file_path(script.project_id, script.file_path)) do
      {:ok, contents} ->
        case Frontmatter.parse_document(contents) do
          {:ok, %{body: body}} -> body
          {:error, _reason} -> ""
        end

      {:error, _reason} ->
        ""
    end
  end

  defp effective_script_content(%Script{} = script) do
    case hydrate_script_content(script) do
      %Script{content: content} when is_binary(content) -> content
      _other -> ""
    end
  end

  defp hydrate_script_content(%Script{} = script) do
    case script do
      %Script{content: content} when is_binary(content) ->
        script

      %Script{status: :published, file_path: file_path} when file_path not in [nil, ""] ->
        %{script | content: published_script_body(script)}

      _other ->
        script
    end
  end

  defp upsert_script_from_file(project_id, project, path) do
    contents = File.read!(path)
    {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)
    relative_path = Path.relative_to(path, Projects.project_data_dir(project))
    now = Persistence.now_ms()

    attrs = %{
      id: DocumentFields.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      slug: DocumentFields.fetch!(fields, "slug"),
      title: DocumentFields.get(fields, "title") || "",
      kind: parse_script_kind(DocumentFields.fetch!(fields, "kind")),
      entrypoint: Map.get(fields, "entrypoint") || "main",
      enabled: Map.get(fields, "enabled", true),
      version: Map.get(fields, "version", 1),
      file_path: relative_path,
      status: :published,
      content: nil,
      created_at: DocumentFields.get(fields, "createdAt", now),
      updated_at: DocumentFields.get(fields, "updatedAt", now)
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

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp progress_callback(opts), do: ProgressReporter.callback(opts)

  defp report_rebuild_started(callback, total, label),
    do: ProgressReporter.report_rebuild_started(callback, total, label)

  defp report_rebuild_progress(callback, current, total, label),
    do: ProgressReporter.report_rebuild_progress(callback, current, total, label)
end
