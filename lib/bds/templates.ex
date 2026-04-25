defmodule BDS.Templates do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Persistence
  alias BDS.Posts
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Slug
  alias BDS.Tags
  alias BDS.Templates.Template

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

  def update_template(template_id, attrs) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      template ->
        next_slug =
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

        content_changed? =
          has_attr?(attrs, :content) and attr(attrs, :content) != template.content

        slug_changed? = next_slug != template.slug
        now = Persistence.now_ms()

        next_status =
          if(template.status == :published and content_changed?,
            do: :draft,
            else: template.status
          )

        next_file_path = next_template_file_path(template, next_slug)

        updates =
          %{}
          |> maybe_put(:title, attr(attrs, :title))
          |> maybe_put(:kind, attr(attrs, :kind))
          |> maybe_put(:enabled, attr(attrs, :enabled))
          |> maybe_put(:content, attr(attrs, :content))
          |> Map.put(:file_path, next_file_path)
          |> Map.put(:slug, next_slug)
          |> Map.put(:version, template.version + 1)
          |> Map.put(:updated_at, now)
          |> Map.put(:status, next_status)

        Repo.transaction(fn ->
          updated_template =
            template
            |> Template.changeset(updates)
            |> Repo.update!()

          if slug_changed? do
            cascade_template_slug_change(template, updated_template, now)
          end

          if template.file_path not in [nil, ""] and next_file_path != template.file_path do
            rewrite_template_file(template, updated_template)
          end

          updated_template
        end)
        |> case do
          {:ok, updated_template} -> {:ok, updated_template}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def rebuild_templates_from_files(project_id) do
    project = Projects.get_project!(project_id)

    templates =
      project
      |> Projects.project_data_dir()
      |> Path.join("templates")
      |> list_matching_files("*.liquid")
      |> Enum.map(&upsert_template_from_file(project_id, project, &1))

    {:ok, templates}
  end

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

            delete_file_if_present(template.project_id, template.file_path)
            Repo.delete!(template)
            {:ok, :deleted}
        end
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

    Enum.each(affected_posts, fn post ->
      Posts.rewrite_published_post(post.id)
    end)

    Tags.sync_tags_json(original_template.project_id)
  end

  defp rewrite_template_file(original_template, updated_template) do
    body = published_template_body(original_template)
    new_full_path = full_file_path(updated_template.project_id, updated_template.file_path)
    :ok = Persistence.atomic_write(new_full_path, serialize_template_file(updated_template, body))

    if original_template.file_path != updated_template.file_path do
      _ = delete_file_if_present(original_template.project_id, original_template.file_path)
    end

    :ok
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

  defp upsert_template_from_file(project_id, project, path) do
    contents = File.read!(path)
    {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)
    relative_path = Path.relative_to(path, Projects.project_data_dir(project))
    now = Persistence.now_ms()

    attrs = %{
      id: Map.get(fields, "id") || Ecto.UUID.generate(),
      project_id: project_id,
      slug: Map.fetch!(fields, "slug"),
      title: Map.get(fields, "title") || "",
      kind: parse_template_kind(Map.fetch!(fields, "kind")),
      enabled: Map.get(fields, "enabled", true),
      version: Map.get(fields, "version", 1),
      file_path: relative_path,
      status: :published,
      content: nil,
      created_at: Map.get(fields, "createdAt", now),
      updated_at: Map.get(fields, "updatedAt", now)
    }

    template = Repo.get_by(Template, project_id: project_id, slug: attrs.slug) || %Template{}

    template
    |> Template.changeset(attrs)
    |> Repo.insert_or_update!()
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
