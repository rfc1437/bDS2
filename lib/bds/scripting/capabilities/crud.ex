defmodule BDS.Scripting.Capabilities.Crud do
  @moduledoc false

  import Ecto.Query
  import BDS.Scripting.Capabilities.Util

  alias BDS.MCP
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Scripting.Capabilities.Posts, as: PostsCaps
  alias BDS.Scripts
  alias BDS.Scripts.Script
  alias BDS.Tags
  alias BDS.Tags.Tag
  alias BDS.Tasks
  alias BDS.Templates
  alias BDS.Templates.Template

  # --- Scripts ---

  def create_script(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Scripts.create_script()
    |> unwrap_result()
  end

  def update_script(project_id, script_id, attrs) do
    case fetch_script(project_id, script_id) do
      %Script{} -> Scripts.update_script(script_id, normalize_map(attrs)) |> unwrap_result()
      _other -> nil
    end
  end

  def delete_script(project_id, script_id) do
    case fetch_script(project_id, script_id) do
      %Script{} -> boolean_result(Scripts.delete_script(script_id))
      _other -> false
    end
  end

  def load_script(project_id, script_id) do
    fetch_script(project_id, script_id)
    |> sanitize_nilable()
  end

  def list_scripts(project_id) do
    Repo.all(
      from(script in Script,
        where: script.project_id == ^project_id,
        order_by: [asc: script.created_at]
      )
    )
    |> Enum.map(&sanitize/1)
  end

  def publish_script(project_id, script_id) do
    case fetch_script(project_id, script_id) do
      %Script{} -> Scripts.publish_script(script_id) |> unwrap_result()
      _other -> nil
    end
  end

  def rebuild_scripts_from_files(project_id) do
    project_id
    |> Scripts.rebuild_scripts_from_files()
    |> unwrap_result()
  end

  def fetch_script(project_id, script_id) do
    Repo.one(
      from(script in Script,
        where:
          script.project_id == ^project_id and script.id == ^(string_or_nil(script_id) || ""),
        limit: 1
      )
    )
  end

  # --- Templates ---

  def create_template(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Templates.create_template()
    |> unwrap_result()
  end

  def update_template(project_id, template_id, attrs) do
    case fetch_template(project_id, template_id) do
      %Template{} ->
        Templates.update_template(template_id, normalize_map(attrs)) |> unwrap_result()

      _other ->
        nil
    end
  end

  def delete_template(project_id, template_id) do
    case fetch_template(project_id, template_id) do
      %Template{} -> boolean_result(Templates.delete_template(template_id))
      _other -> false
    end
  end

  def load_template(project_id, template_id) do
    fetch_template(project_id, template_id)
    |> sanitize_nilable()
  end

  def list_templates(project_id) do
    Repo.all(
      from(template in Template,
        where: template.project_id == ^project_id,
        order_by: [asc: template.created_at]
      )
    )
    |> Enum.map(&sanitize/1)
  end

  def publish_template(project_id, template_id) do
    case fetch_template(project_id, template_id) do
      %Template{} -> Templates.publish_template(template_id) |> unwrap_result()
      _other -> nil
    end
  end

  def list_enabled_templates(project_id, kind) do
    Repo.all(
      from(template in Template,
        where:
          template.project_id == ^project_id and template.enabled == true and
            template.kind == ^string_or_nil(kind),
        order_by: [asc: template.created_at]
      )
    )
    |> Enum.map(&sanitize/1)
  end

  def rebuild_templates_from_files(project_id) do
    project_id
    |> Templates.rebuild_templates_from_files()
    |> unwrap_result()
  end

  def validate_template_source(source) do
    source
    |> string_or_nil()
    |> Kernel.||("")
    |> MCP.validate_template()
    |> unwrap_result()
  end

  def fetch_template(project_id, template_id) do
    Repo.one(
      from(template in Template,
        where:
          template.project_id == ^project_id and
            template.id == ^(string_or_nil(template_id) || ""),
        limit: 1
      )
    )
  end

  # --- Tags ---

  def create_tag(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Tags.create_tag()
    |> unwrap_result()
  end

  def update_tag(project_id, tag_id, attrs) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> Tags.update_tag(tag_id, normalize_map(attrs)) |> unwrap_result()
      _other -> nil
    end
  end

  def delete_tag(project_id, tag_id) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> boolean_result(Tags.delete_tag(tag_id))
      _other -> false
    end
  end

  def load_tag(project_id, tag_id) do
    fetch_tag(project_id, tag_id)
    |> sanitize_nilable()
  end

  def list_tags(project_id) do
    Tags.list_tags(project_id)
    |> Enum.map(&sanitize/1)
  end

  def tags_with_counts(project_id) do
    counts_by_name =
      PostsCaps.names_with_counts(project_id, :tags)
      |> Map.new(fn entry -> {entry["name"], entry["count"]} end)

    list_tags(project_id)
    |> Enum.map(fn tag -> Map.put(tag, "count", Map.get(counts_by_name, tag["name"], 0)) end)
  end

  def tag_post_ids(project_id, tag_id) do
    case fetch_tag(project_id, tag_id) do
      %Tag{name: tag_name} ->
        Repo.all(
          from(post in Post,
            where:
              post.project_id == ^project_id and
                fragment(
                  "EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)",
                  post.tags,
                  ^tag_name
                ),
            order_by: [asc: post.created_at],
            select: post.id
          )
        )

      _other ->
        []
    end
  end

  def load_tag_by_name(project_id, tag_name) do
    Repo.one(
      from(tag in Tag,
        where:
          tag.project_id == ^project_id and
            fragment("lower(?)", tag.name) == ^String.downcase(string_or_nil(tag_name) || ""),
        limit: 1
      )
    )
    |> sanitize_nilable()
  end

  def rename_tag(project_id, tag_id, new_name) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> Tags.rename_tag(tag_id, string_or_nil(new_name) || "") |> unwrap_result()
      _other -> nil
    end
  end

  def merge_tags(project_id, source_tag_ids, target_tag_id) do
    case fetch_tag(project_id, target_tag_id) do
      %Tag{} ->
        atom_result(
          Tags.merge_tags(normalize_string_list(source_tag_ids), target_tag_id),
          :merged
        )

      _other ->
        false
    end
  end

  def sync_tags_from_posts(project_id) do
    Tags.sync_tags_from_posts(project_id)
    |> unwrap_result()
  end

  def fetch_tag(project_id, tag_id) do
    Repo.one(
      from(tag in Tag,
        where: tag.project_id == ^project_id and tag.id == ^(string_or_nil(tag_id) || ""),
        limit: 1
      )
    )
  end

  # --- Tasks ---

  def load_task(task_id) do
    case string_or_nil(task_id) do
      nil -> nil
      id -> Tasks.get_task(id) |> sanitize_nilable()
    end
  end

  def cancel_task(task_id) do
    case string_or_nil(task_id) do
      nil -> false
      id -> match?(:ok, Tasks.cancel_task(id))
    end
  end

  def list_all_tasks do
    Tasks.list_tasks()
    |> Enum.map(&sanitize/1)
  end

  def list_running_tasks do
    Tasks.list_running_tasks()
    |> Enum.map(&sanitize/1)
  end

  def clear_completed_tasks do
    match?(:ok, Tasks.clear_completed())
  end
end
