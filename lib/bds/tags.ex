defmodule BDS.Tags do
  @moduledoc false

  import Ecto.Query

  alias BDS.Persistence
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Tags.Tag

  def create_tag(attrs) do
    project_id = attr(attrs, :project_id)
    name = attr(attrs, :name) |> to_string() |> String.trim()

    with :ok <- validate_unique_name(project_id, name) do
      now = Persistence.now_ms()

      %Tag{}
      |> Tag.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        name: name,
        color: attr(attrs, :color),
        post_template_slug: attr(attrs, :post_template_slug),
        created_at: now,
        updated_at: now
      })
      |> Repo.insert()
      |> case do
        {:ok, tag} ->
          with :ok <- write_tags_json(project_id) do
            {:ok, tag}
          end

        error ->
          error
      end
    end
  end

  def list_tags(project_id) do
    Repo.all(from tag in Tag, where: tag.project_id == ^project_id, order_by: [asc: tag.name])
  end

  def sync_tags_json(project_id) do
    write_tags_json(project_id)
    :ok
  end

  def sync_tags_from_posts(project_id) do
    Repo.transaction(fn ->
      existing_names =
        project_id
        |> list_tags()
        |> Enum.map(&String.downcase(&1.name))
        |> MapSet.new()

      missing_names =
        project_id
        |> post_tag_names()
        |> Enum.reduce({existing_names, []}, fn tag_name, {seen_names, acc} ->
          normalized = String.downcase(tag_name)

          if MapSet.member?(seen_names, normalized) do
            {seen_names, acc}
          else
            {MapSet.put(seen_names, normalized), [tag_name | acc]}
          end
        end)
        |> elem(1)
        |> Enum.reverse()

      now = Persistence.now_ms()

      Enum.each(missing_names, fn name ->
        %Tag{}
        |> Tag.changeset(%{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          name: name,
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()
      end)

      list_tags(project_id)
    end)
    |> case do
      {:ok, tags} ->
        with :ok <- write_tags_json(project_id) do
          {:ok, tags}
        end

      {:error, reason} -> {:error, reason}
    end
  end

  def update_tag(tag_id, attrs) do
    case Repo.get(Tag, tag_id) do
      nil ->
        {:error, :not_found}

      tag ->
        updates = %{
          color: attr(attrs, :color),
          post_template_slug: attr(attrs, :post_template_slug),
          updated_at: Persistence.now_ms()
        }

        tag
        |> Tag.changeset(updates)
        |> Repo.update()
        |> case do
          {:ok, updated_tag} ->
            with :ok <- write_tags_json(updated_tag.project_id) do
              {:ok, updated_tag}
            end

          error ->
            error
        end
    end
  end

  def delete_tag(tag_id) do
    case Repo.get(Tag, tag_id) do
      nil ->
        {:error, :not_found}

      tag ->
        Repo.transaction(fn ->
          affected_posts = posts_with_tag(tag.project_id, tag.name)

          Enum.each(affected_posts, fn post ->
            updated_tags = Enum.reject(post.tags || [], &(&1 == tag.name))
            update_post_tags(post, updated_tags)
          end)

          Repo.delete!(tag)
          Enum.map(affected_posts, & &1.id)
        end)
        |> case do
          {:ok, post_ids} ->
            with :ok <- rewrite_published_posts(post_ids),
                 :ok <- write_tags_json(tag.project_id) do
              {:ok, :deleted}
            end

          {:error, reason} -> {:error, reason}
        end
    end
  end

  def rename_tag(tag_id, new_name) do
    case Repo.get(Tag, tag_id) do
      nil ->
        {:error, :not_found}

      tag ->
        normalized_name = String.trim(new_name)

        with :ok <- validate_rename_target(tag.project_id, tag.id, normalized_name) do
          old_name = tag.name

          Repo.transaction(fn ->
            affected_posts = posts_with_tag(tag.project_id, old_name)

            Enum.each(affected_posts, fn post ->
              updated_tags = replace_tag(post.tags || [], old_name, normalized_name)
              update_post_tags(post, updated_tags)
            end)

            updated_tag =
              tag
              |> Tag.changeset(%{name: normalized_name, updated_at: Persistence.now_ms()})
              |> Repo.update!()

            {updated_tag, Enum.map(affected_posts, & &1.id)}
          end)
          |> case do
            {:ok, {updated_tag, post_ids}} ->
              with :ok <- rewrite_published_posts(post_ids),
                   :ok <- write_tags_json(tag.project_id) do
                {:ok, updated_tag}
              end

            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  def merge_tags(source_tag_ids, target_tag_id) do
    case Repo.get(Tag, target_tag_id) do
      nil ->
        {:error, :not_found}

      target_tag ->
        source_tags =
          Repo.all(
            from tag in Tag,
              where: tag.id in ^source_tag_ids and tag.project_id == ^target_tag.project_id
          )

        Repo.transaction(fn ->
          source_names = Enum.map(source_tags, & &1.name)
          affected_posts = posts_with_any_tag(target_tag.project_id, source_names)

          Enum.each(affected_posts, fn post ->
            updated_tags = merge_post_tags(post.tags || [], source_names, target_tag.name)
            update_post_tags(post, updated_tags)
          end)

          Enum.each(source_tags, &Repo.delete!/1)
          Enum.map(affected_posts, & &1.id)
        end)
        |> case do
          {:ok, post_ids} ->
            with :ok <- rewrite_published_posts(post_ids),
                 :ok <- write_tags_json(target_tag.project_id) do
              {:ok, :merged}
            end

          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp write_tags_json(project_id) do
    project = Projects.get_project!(project_id)
    path = Path.join([Projects.project_data_dir(project), "meta", "tags.json"])

    payload =
      project_id
      |> list_tags()
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(fn tag ->
        %{"name" => tag.name}
        |> maybe_put("color", tag.color)
        |> maybe_put("postTemplateSlug", tag.post_template_slug)
      end)

    Persistence.atomic_write(path, Jason.encode!(payload))
  end

  defp validate_unique_name(project_id, name) do
    if Repo.exists?(
         from tag in Tag,
           where:
             tag.project_id == ^project_id and
               fragment("lower(?)", tag.name) == ^String.downcase(name)
       ) do
      {:error,
       %Tag{}
       |> Tag.changeset(%{
         project_id: project_id,
         name: name,
         id: Ecto.UUID.generate(),
         created_at: 0,
         updated_at: 0
       })
       |> Ecto.Changeset.add_error(:name, "has already been taken")}
    else
      :ok
    end
  end

  defp validate_rename_target(project_id, tag_id, name) do
    if Repo.exists?(
         from tag in Tag,
           where:
             tag.project_id == ^project_id and tag.id != ^tag_id and
               fragment("lower(?)", tag.name) == ^String.downcase(name)
       ) do
      {:error,
       %Tag{}
       |> Tag.changeset(%{
         project_id: project_id,
         name: name,
         id: tag_id,
         created_at: 0,
         updated_at: 0
       })
       |> Ecto.Changeset.add_error(:name, "has already been taken")}
    else
      :ok
    end
  end

  defp posts_with_tag(project_id, tag_name) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.filter(fn post -> tag_name in (post.tags || []) end)
  end

  defp posts_with_any_tag(project_id, tag_names) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.filter(fn post -> Enum.any?(post.tags || [], &(&1 in tag_names)) end)
  end

  defp post_tag_names(project_id) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.flat_map(fn post ->
      post.tags
      |> Kernel.||([])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp replace_tag(tags, old_name, new_name) do
    tags
    |> Enum.map(fn tag -> if tag == old_name, do: new_name, else: tag end)
    |> Enum.uniq()
  end

  defp merge_post_tags(tags, source_names, target_name) do
    retained_tags = Enum.reject(tags, &(&1 in source_names))

    if target_name in retained_tags do
      retained_tags
    else
      retained_tags ++ [target_name]
    end
  end

  defp update_post_tags(post, updated_tags) do
    post
    |> Post.changeset(%{tags: updated_tags, updated_at: Persistence.now_ms()})
    |> Repo.update!()
  end

  defp rewrite_published_posts(post_ids) do
    Enum.each(post_ids, &Posts.rewrite_published_post/1)
    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
