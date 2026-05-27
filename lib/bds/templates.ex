defmodule BDS.Templates do
  @moduledoc """
  CRUD and lifecycle management for Liquid templates (posts, lists, partials, 404 pages),
  including slug derivation, status transitions, and filesystem synchronization.
  """

  require Logger

  import Ecto.Query
  import BDS.MapUtils, only: [attr: 2, maybe_put: 3]

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.ProgressReporter
  alias BDS.Posts
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Slug
  alias BDS.Tags
  alias BDS.Templates.Template

  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}
  @type template_result :: {:ok, Template.t()} | {:error, Ecto.Changeset.t() | term()}

  @spec create_template(attrs()) :: {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def create_template(attrs) do
    now = Persistence.now_ms()
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

  @spec get_template(String.t()) :: Template.t() | nil
  def get_template(template_id) do
    case Repo.get(Template, template_id) do
      %Template{} = template -> hydrate_template_content(template)
      nil -> nil
    end
  end

  @spec publish_template(String.t()) :: template_result() | {:error, :not_found}
  def publish_template(template_id) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      template ->
        file_path = template_file_path(template.slug)
        full_path = full_file_path(template.project_id, file_path)
        updated_at = Persistence.now_ms()
        content = template.content || ""

        :ok =
          Persistence.atomic_write(
            full_path,
            serialize_template_file(
              %{template | status: :published, file_path: file_path, updated_at: updated_at},
              content
            )
          )

        template
        |> Template.changeset(%{
          status: :published,
          file_path: file_path,
          content: nil,
          updated_at: updated_at
        })
        |> Repo.update()
    end
  end

  @spec update_template(String.t(), attrs()) :: template_result() | {:error, :not_found}
  def update_template(template_id, attrs) do
    with %Template{} = template <- Repo.get(Template, template_id) do
      do_update_template(template, attrs)
    else
      nil -> {:error, :not_found}
    end
  end

  defp do_update_template(template, attrs) do
    now = Persistence.now_ms()
    next_slug = resolve_next_slug(template, attrs)
    slug_changed? = next_slug != template.slug
    content_changed? = content_changed?(template, attrs)
    next_status = resolve_next_status(template, content_changed?)
    updates = build_update_attrs(template, attrs, next_slug, next_status, now)

    with {:ok, {updated_template, affected_posts}} <-
           commit_update_transaction(template, updates, slug_changed?, now),
         :ok <-
           sync_template_update_side_effects(
             template,
             updated_template,
             affected_posts,
             slug_changed?
           ) do
      {:ok, updated_template}
    end
  end

  defp resolve_next_slug(template, attrs) do
    if has_attr?(attrs, :slug) do
      unique_slug(
        template.project_id,
        Slug.slugify(attr(attrs, :slug)),
        "template",
        template.id
      )
    else
      template.slug
    end
  end

  defp content_changed?(template, attrs) do
    has_attr?(attrs, :content) and
      attr(attrs, :content) != effective_template_content(template)
  end

  defp resolve_next_status(%Template{status: :published}, true = _content_changed?), do: :draft
  defp resolve_next_status(%Template{status: status}, _content_changed?), do: status

  defp build_update_attrs(template, attrs, next_slug, next_status, now) do
    %{}
    |> maybe_put(:title, attr(attrs, :title))
    |> maybe_put(:kind, attr(attrs, :kind))
    |> maybe_put(:enabled, attr(attrs, :enabled))
    |> maybe_put(:content, attr(attrs, :content))
    |> Map.put(:file_path, next_template_file_path(template, next_slug))
    |> Map.put(:slug, next_slug)
    |> Map.put(:version, template.version + 1)
    |> Map.put(:updated_at, now)
    |> Map.put(:status, next_status)
  end

  defp commit_update_transaction(template, updates, slug_changed?, now) do
    Repo.transaction(fn ->
      updated_template =
        template
        |> Template.changeset(updates)
        |> Repo.update!()

      affected_posts =
        if slug_changed? do
          cascade_template_slug_change(template, updated_template, now)
        else
          []
        end

      {updated_template, affected_posts}
    end)
  end

  @spec rebuild_templates_from_files(String.t(), keyword()) :: {:ok, [Template.t()]}
  def rebuild_templates_from_files(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)

    template_paths =
      project
      |> Projects.project_data_dir()
      |> Path.join("templates")
      |> list_matching_files("*.liquid")

    total_files = length(template_paths)
    on_progress = progress_callback(opts)
    :ok = report_rebuild_started(on_progress, total_files, "template files")

    templates =
      template_paths
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {path, index} ->
        result = upsert_template_from_file(project_id, project, path)
        :ok = report_rebuild_progress(on_progress, index, total_files, "template files")

        case result do
          {:ok, template} ->
            [template]

          {:error, reason} ->
            Logger.warning("Skipping template #{path}: #{inspect(reason)}")
            []
        end
      end)

    remove_stale_published_templates(project_id, project, template_paths)

    {:ok, templates}
  end

  @spec delete_template(String.t(), keyword()) ::
          {:ok, :deleted} | {:error, :not_found | {:has_references, map()} | term()}
  def delete_template(template_id, opts \\ []) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      template ->
        post_count = count_referencing_posts(template)
        tag_count = count_referencing_tags(template)
        force? = Keyword.get(opts, :force, false)

        cond do
          not force? and (post_count > 0 or tag_count > 0) ->
            {:error, {:has_references, %{posts: post_count, tags: tag_count}}}

          true ->
            if force? do
              clear_template_references(template)
            end

            case Repo.delete(template) do
              {:ok, deleted_template} ->
                delete_file_if_present(deleted_template.project_id, deleted_template.file_path)
                {:ok, :deleted}

              {:error, changeset} ->
                {:error, changeset}
            end
        end
    end
  end

  @spec sync_template_from_file(String.t()) :: {:ok, Template.t()} | {:error, :not_found}
  def sync_template_from_file(template_id) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      %Template{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Template{} = template ->
        project = Projects.get_project!(template.project_id)
        full_path = Path.join(Projects.project_data_dir(project), template.file_path)

        case upsert_template_from_file(template.project_id, project, full_path) do
          {:ok, _template} = ok -> ok
          {:error, _reason} -> {:error, :not_found}
        end
    end
  end

  @spec sync_published_template_file(String.t()) :: {:ok, Template.t()} | {:error, :not_found}
  def sync_published_template_file(template_id) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      %Template{file_path: file_path, status: status} = template
      when file_path not in [nil, ""] and status == :published ->
        full_path = full_file_path(template.project_id, template.file_path)

        :ok =
          Persistence.atomic_write(
            full_path,
            serialize_template_file(template, published_template_body(template))
          )

        {:ok, template}

      %Template{} ->
        {:error, :not_found}
    end
  end

  @spec import_orphan_template_file(String.t(), String.t()) ::
          {:ok, Template.t()} | {:error, :not_found}
  def import_orphan_template_file(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case upsert_template_from_file(project_id, project, full_path) do
      {:ok, _template} = ok -> ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

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
      from template in Template,
        where: template.project_id == ^project_id and template.slug == ^slug

    scoped_query =
      case exclude_id do
        nil -> query
        _id -> from template in query, where: template.id != ^exclude_id
      end

    not Repo.exists?(scoped_query)
  end

  defp template_file_path(slug), do: Path.join(["templates", "#{slug}.liquid"])

  defp full_file_path(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    Path.join(Projects.project_data_dir(project), relative_path)
  end

  defp next_template_file_path(%Template{file_path: ""}, _next_slug), do: ""
  defp next_template_file_path(%Template{}, next_slug), do: template_file_path(next_slug)

  defp serialize_template_file(template, content) do
    Frontmatter.serialize_document(
      [
        {"id", template.id},
        {"projectId", template.project_id},
        {"slug", template.slug},
        {"title", template.title},
        {"kind", template.kind},
        {"enabled", template.enabled},
        {"version", template.version},
        {"createdAt", template.created_at},
        {"updatedAt", template.updated_at}
      ],
      content
    )
  end

  defp count_referencing_posts(template) do
    Repo.aggregate(
      from(post in BDS.Posts.Post,
        where: post.project_id == ^template.project_id and post.template_slug == ^template.slug
      ),
      :count,
      :id
    )
  end

  defp count_referencing_tags(template) do
    Repo.aggregate(
      from(tag in BDS.Tags.Tag,
        where: tag.project_id == ^template.project_id and tag.post_template_slug == ^template.slug
      ),
      :count,
      :id
    )
  end

  defp clear_template_references(template) do
    now = Persistence.now_ms()

    affected_posts =
      Repo.all(
        from(post in BDS.Posts.Post,
          where: post.project_id == ^template.project_id and post.template_slug == ^template.slug
        )
      )

    from(post in BDS.Posts.Post,
      where: post.project_id == ^template.project_id and post.template_slug == ^template.slug
    )
    |> Repo.update_all(set: [template_slug: nil, updated_at: now])

    from(tag in BDS.Tags.Tag,
      where: tag.project_id == ^template.project_id and tag.post_template_slug == ^template.slug
    )
    |> Repo.update_all(set: [post_template_slug: nil, updated_at: now])

    Enum.each(affected_posts, fn post ->
      Posts.rewrite_published_post(post.id)
    end)

    Tags.sync_tags_json(template.project_id)

    :ok
  end

  defp cascade_template_slug_change(original_template, updated_template, updated_at) do
    affected_posts =
      Repo.all(
        from(post in BDS.Posts.Post,
          where:
            post.project_id == ^original_template.project_id and
              post.template_slug == ^original_template.slug
        )
      )

    from(post in BDS.Posts.Post,
      where:
        post.project_id == ^original_template.project_id and
          post.template_slug == ^original_template.slug
    )
    |> Repo.update_all(set: [template_slug: updated_template.slug, updated_at: updated_at])

    from(tag in BDS.Tags.Tag,
      where:
        tag.project_id == ^original_template.project_id and
          tag.post_template_slug == ^original_template.slug
    )
    |> Repo.update_all(set: [post_template_slug: updated_template.slug, updated_at: updated_at])

    affected_posts
  end

  defp sync_template_update_side_effects(
         original_template,
         updated_template,
         affected_posts,
         slug_changed?
       ) do
    Enum.each(affected_posts, fn post ->
      Posts.rewrite_published_post(post.id)
    end)

    if slug_changed? do
      Tags.sync_tags_json(original_template.project_id)
    end

    if original_template.file_path not in [nil, ""] and
         updated_template.file_path != original_template.file_path do
      rewrite_template_file(original_template, updated_template)
    else
      :ok
    end
  end

  defp rewrite_template_file(original_template, updated_template) do
    body = published_template_body(original_template)
    new_full_path = full_file_path(updated_template.project_id, updated_template.file_path)

    case Persistence.atomic_write(new_full_path, serialize_template_file(updated_template, body)) do
      :ok when original_template.file_path != updated_template.file_path ->
        delete_file_if_present(original_template.project_id, original_template.file_path)

      other ->
        other
    end
  end

  defp published_template_body(%Template{content: content}) when is_binary(content), do: content

  defp published_template_body(template) do
    case File.read(full_file_path(template.project_id, template.file_path)) do
      {:ok, contents} ->
        case Frontmatter.parse_document(contents) do
          {:ok, %{body: body}} -> body
          {:error, _reason} -> ""
        end

      {:error, _reason} ->
        ""
    end
  end

  defp effective_template_content(%Template{} = template) do
    case hydrate_template_content(template) do
      %Template{content: content} when is_binary(content) -> content
      _other -> ""
    end
  end

  defp hydrate_template_content(%Template{} = template) do
    case template do
      %Template{content: content} when is_binary(content) ->
        template

      %Template{status: :published, file_path: file_path} when file_path not in [nil, ""] ->
        %{template | content: published_template_body(template)}

      _other ->
        template
    end
  end

  defp upsert_template_from_file(project_id, project, path) do
    relative_path = Path.relative_to(path, Projects.project_data_dir(project))

    with {:ok, contents} <- File.read(path),
         {:ok, %{fields: fields}} <- Frontmatter.parse_document(contents) do
      now = Persistence.now_ms()

      attrs = %{
        id: DocumentFields.get(fields, "id") || Ecto.UUID.generate(),
        project_id: project_id,
        slug: DocumentFields.fetch!(fields, "slug"),
        title: DocumentFields.get(fields, "title") || "",
        kind: parse_template_kind(DocumentFields.fetch!(fields, "kind")),
        enabled: Map.get(fields, "enabled", true),
        version: Map.get(fields, "version", 1),
        file_path: relative_path,
        status: :published,
        content: nil,
        created_at: DocumentFields.get(fields, "createdAt", now),
        updated_at: DocumentFields.get(fields, "updatedAt", now)
      }

      template = Repo.get_by(Template, project_id: project_id, slug: attrs.slug) || %Template{}

      template
      |> Template.changeset(attrs)
      |> Repo.insert_or_update()
    end
  end

  defp remove_stale_published_templates(project_id, project, template_paths) do
    tracked_paths =
      template_paths
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> MapSet.new()

    Repo.all(
      from template in Template,
        where:
          template.project_id == ^project_id and
            template.status == :published and
            template.file_path != "" and
            not is_nil(template.file_path)
    )
    |> Enum.reject(
      &(MapSet.member?(tracked_paths, &1.file_path) or
          File.exists?(full_file_path(project_id, &1.file_path)))
    )
    |> Enum.each(fn template ->
      clear_template_references(template)

      case Repo.delete(template) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  defp parse_template_kind(kind) when is_atom(kind), do: kind
  defp parse_template_kind("post"), do: :post
  defp parse_template_kind("list"), do: :list
  defp parse_template_kind("not_found"), do: :not_found
  defp parse_template_kind("partial"), do: :partial

  defp list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join(dir, pattern)
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
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

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp progress_callback(opts), do: ProgressReporter.callback(opts)

  defp report_rebuild_started(callback, total, label),
    do: ProgressReporter.report_rebuild_started(callback, total, label)

  defp report_rebuild_progress(callback, current, total, label),
    do: ProgressReporter.report_rebuild_progress(callback, current, total, label)
end
