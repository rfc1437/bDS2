defmodule BDS.Templates do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Projects
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

  def publish_template(template_id) do
    case Repo.get(Template, template_id) do
      nil ->
        {:error, :not_found}

      template ->
        file_path = template_file_path(template.slug)
        full_path = full_file_path(template.project_id, file_path)
        updated_at = System.system_time(:second)
        content = template.content || ""

        :ok = File.mkdir_p(Path.dirname(full_path))

        :ok =
          File.write(
            full_path,
            serialize_template_file(%{template | status: :published, file_path: file_path, updated_at: updated_at}, content)
          )

        template
        |> Template.changeset(%{status: :published, file_path: file_path, content: nil, updated_at: updated_at})
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
            unique_slug(template.project_id, Slug.slugify(attr(attrs, :slug)), "template", template.id)
          else
            template.slug
          end

        content_changed? = has_attr?(attrs, :content) and attr(attrs, :content) != template.content
        now = System.system_time(:second)

        updates = %{}
        |> maybe_put(:title, attr(attrs, :title))
        |> maybe_put(:kind, attr(attrs, :kind))
        |> maybe_put(:enabled, attr(attrs, :enabled))
        |> maybe_put(:content, attr(attrs, :content))
        |> Map.put(:slug, next_slug)
        |> Map.put(:version, template.version + 1)
        |> Map.put(:updated_at, now)
        |> maybe_put(:status, if(template.status == :published and content_changed?, do: :draft, else: nil))

        template
        |> Template.changeset(updates)
        |> Repo.update()
    end
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
    query = from template in Template, where: template.project_id == ^project_id and template.slug == ^slug

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

  defp serialize_template_file(template, content) do
    Frontmatter.serialize_document(
      [
        {:id, template.id},
        {:slug, template.slug},
        {:title, template.title},
        {:kind, template.kind},
        {:enabled, template.enabled},
        {:version, template.version},
        {:created_at, template.created_at},
        {:updated_at, template.updated_at}
      ],
      content
    )
  end

  defp count_referencing_posts(template) do
    Repo.aggregate(from(post in BDS.Posts.Post, where: post.project_id == ^template.project_id and post.template_slug == ^template.slug), :count, :id)
  end

  defp count_referencing_tags(template) do
    Repo.aggregate(from(tag in BDS.Tags.Tag, where: tag.project_id == ^template.project_id and tag.post_template_slug == ^template.slug), :count, :id)
  end

  defp clear_template_references(template) do
    now = System.system_time(:second)

    affected_posts =
      Repo.all(
        from(post in BDS.Posts.Post,
          where: post.project_id == ^template.project_id and post.template_slug == ^template.slug
        )
      )

    from(post in BDS.Posts.Post, where: post.project_id == ^template.project_id and post.template_slug == ^template.slug)
    |> Repo.update_all(set: [template_slug: nil, updated_at: now])

    from(tag in BDS.Tags.Tag, where: tag.project_id == ^template.project_id and tag.post_template_slug == ^template.slug)
    |> Repo.update_all(set: [post_template_slug: nil, updated_at: now])

    Enum.each(affected_posts, fn post ->
      BDS.Posts.rewrite_published_post(post.id)
    end)

    BDS.Tags.sync_tags_json(template.project_id)

    :ok
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
