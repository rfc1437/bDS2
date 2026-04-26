defmodule BDS.Desktop.ShellLive.TagsEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.ShellData
  alias BDS.{Repo, Tags}
  alias BDS.Posts.Post
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  embed_templates "tags_editor_html/*"

  def assign_socket(socket) do
    assign(socket, :tags_editor, build(socket.assigns))
  end

  def toggle_selection(socket, tag_name, reload) do
    selected = Map.get(socket.assigns, :tags_editor_selected, [])

    next_selected =
      if tag_name in selected do
        Enum.reject(selected, &(&1 == tag_name))
      else
        selected ++ [tag_name]
      end

    socket
    |> assign(:tags_editor_selected, next_selected)
    |> maybe_seed_edit_draft(next_selected)
    |> reload.(socket.assigns.workbench)
  end

  def update_new_tag(socket, params, reload) do
    socket
    |> assign(:tags_editor_new_tag, %{
      "name" => Map.get(params, "name", ""),
      "color" => Map.get(params, "color", "")
    })
    |> reload.(socket.assigns.workbench)
  end

  def create_tag(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    draft = Map.get(socket.assigns, :tags_editor_new_tag, %{})

    case Tags.create_tag(%{project_id: project_id, name: Map.get(draft, "name"), color: blank_to_nil(Map.get(draft, "color"))}) do
      {:ok, _tag} ->
        socket
        |> assign(:tags_editor_new_tag, %{"name" => "", "color" => ""})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Tags"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def update_edit_tag(socket, params, reload) do
    socket
    |> assign(:tags_editor_edit_draft, %{
      "name" => Map.get(params, "name", ""),
      "color" => Map.get(params, "color", ""),
      "post_template_slug" => Map.get(params, "post_template_slug", "")
    })
    |> reload.(socket.assigns.workbench)
  end

  def save_tag(socket, reload, append_output) do
    selected = Map.get(socket.assigns, :tags_editor_selected, [])
    draft = Map.get(socket.assigns, :tags_editor_edit_draft, %{})

    case selected do
      [tag_name] ->
        case Repo.get_by(Tag, project_id: socket.assigns.projects.active_project_id, name: tag_name) do
          nil -> reload.(socket, socket.assigns.workbench)
          %Tag{} = tag ->
            with {:ok, _updated_tag} <- Tags.update_tag(tag.id, %{color: blank_to_nil(Map.get(draft, "color")), post_template_slug: blank_to_nil(Map.get(draft, "post_template_slug"))}),
                 {:ok, renamed_tag} <- maybe_rename_tag(tag, Map.get(draft, "name", tag.name)) do
              socket
              |> assign(:tags_editor_selected, [renamed_tag.name])
              |> maybe_seed_edit_draft([renamed_tag.name])
              |> reload.(socket.assigns.workbench)
            else
              {:error, reason} ->
                socket
                |> append_output.(translated("Tags"), inspect(reason), nil, "error")
                |> reload.(socket.assigns.workbench)
            end
        end

      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def delete_selected(socket, reload, append_output) do
    case Map.get(socket.assigns, :tags_editor_selected, []) do
      [tag_name] ->
        case Repo.get_by(Tag, project_id: socket.assigns.projects.active_project_id, name: tag_name) do
          nil -> reload.(socket, socket.assigns.workbench)
          %Tag{} = tag ->
            case Tags.delete_tag(tag.id) do
              {:ok, _deleted} ->
                socket
                |> assign(:tags_editor_selected, [])
                |> assign(:tags_editor_edit_draft, %{})
                |> reload.(socket.assigns.workbench)

              {:error, reason} ->
                socket
                |> append_output.(translated("Tags"), inspect(reason), nil, "error")
                |> reload.(socket.assigns.workbench)
            end
        end

      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def update_merge_target(socket, target, reload) do
    socket
    |> assign(:tags_editor_merge_target, to_string(target || ""))
    |> reload.(socket.assigns.workbench)
  end

  def merge_selected(socket, reload, append_output) do
    selected = Map.get(socket.assigns, :tags_editor_selected, [])
    target_name = Map.get(socket.assigns, :tags_editor_merge_target, "")

    cond do
      length(selected) < 2 or target_name == "" ->
        reload.(socket, socket.assigns.workbench)

      true ->
        project_id = socket.assigns.projects.active_project_id
        tags = Repo.all(from tag in Tag, where: tag.project_id == ^project_id and tag.name in ^selected)
        target = Enum.find(tags, &(&1.name == target_name))
        sources = Enum.reject(tags, &(&1.name == target_name))

        case target do
          nil -> reload.(socket, socket.assigns.workbench)
          _target ->
            case Tags.merge_tags(Enum.map(sources, & &1.id), target.id) do
              {:ok, _merged} ->
                socket
                |> assign(:tags_editor_selected, [target.name])
                |> assign(:tags_editor_merge_target, target.name)
                |> maybe_seed_edit_draft([target.name])
                |> reload.(socket.assigns.workbench)

              {:error, reason} ->
                socket
                |> append_output.(translated("Tags"), inspect(reason), nil, "error")
                |> reload.(socket.assigns.workbench)
            end
        end
    end
  end

  def sync(socket, reload, append_output) do
    _ = append_output
    :ok = Tags.sync_tags_json(socket.assigns.projects.active_project_id)
    reload.(socket, socket.assigns.workbench)
  end

  def build(%{current_tab: %{type: :tags}} = assigns) do
    project_id = assigns.projects.active_project_id
    tags = Repo.all(from tag in Tag, where: tag.project_id == ^project_id, order_by: [asc: tag.name])
    counts = tag_counts(project_id)
    selected = Map.get(assigns, :tags_editor_selected, [])
    edit_tag = if length(selected) == 1, do: Enum.find(tags, &(&1.name == hd(selected))), else: nil
    edit_draft = Map.get(assigns, :tags_editor_edit_draft, edit_draft(edit_tag))
    templates = Repo.all(from template in Template, where: template.project_id == ^project_id, order_by: [asc: template.title], select: %{slug: template.slug, title: template.title})

    %{
      tags: Enum.map(tags, fn tag -> %{name: tag.name, color: tag.color, count: Map.get(counts, tag.name, 0)} end),
      selected: selected,
      new_tag: Map.get(assigns, :tags_editor_new_tag, %{"name" => "", "color" => ""}),
      edit_draft: edit_draft,
      templates: templates,
      merge_target: Map.get(assigns, :tags_editor_merge_target, List.first(selected) || "")
    }
  end

  def build(_assigns), do: nil

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  def tag_font_size(count, counts) do
    max_count = Enum.max([1 | Enum.map(counts, & &1.count)])
    ratio = if max_count <= 1, do: 0.0, else: (count - 1) / max(max_count - 1, 1)
    Float.round(0.85 + (1.8 - 0.85) * ratio, 2)
  end

  def tag_style(tag, counts) do
    size = tag_font_size(tag.count, counts)

    [
      "font-size: #{size}rem",
      if(tag.color, do: "background-color: #{tag.color}"),
      if(tag.color, do: "color: #ffffff")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp maybe_seed_edit_draft(socket, [tag_name]) do
    case Repo.get_by(Tag, project_id: socket.assigns.projects.active_project_id, name: tag_name) do
      %Tag{} = tag -> assign(socket, :tags_editor_edit_draft, edit_draft(tag))
      _other -> assign(socket, :tags_editor_edit_draft, %{})
    end
  end

  defp maybe_seed_edit_draft(socket, _selected), do: assign(socket, :tags_editor_edit_draft, %{})

  defp edit_draft(nil), do: %{}
  defp edit_draft(%Tag{} = tag), do: %{"name" => tag.name, "color" => tag.color || "", "post_template_slug" => tag.post_template_slug || ""}

  defp maybe_rename_tag(%Tag{} = tag, next_name) do
    normalized = String.trim(to_string(next_name || tag.name))

    if normalized == tag.name do
      {:ok, tag}
    else
      Tags.rename_tag(tag.id, normalized)
    end
  end

  defp tag_counts(project_id) do
    Repo.all(from post in Post, where: post.project_id == ^project_id, select: post.tags)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn tag, acc -> Map.update(acc, tag, 1, &(&1 + 1)) end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end