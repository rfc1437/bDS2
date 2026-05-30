defmodule BDS.Desktop.ShellLive.TagsEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  import Ecto.Query

  alias BDS.{Repo, Tags}
  alias BDS.Desktop.ShellLive.Notify
  alias BDS.Posts.Post
  alias BDS.Tags.Tag
  alias BDS.Templates.Template
  use Gettext, backend: BDS.Gettext

  embed_templates("tags_editor_html/*")

  @tags_sections ~w(cloud manage merge)

  @colour_presets ~w(
    #ef4444 #f97316 #f59e0b #eab308 #84cc16
    #22c55e #10b981 #14b8a6 #06b6d4 #0ea5e9
    #3b82f6 #6366f1 #8b5cf6 #a855f7 #d946ef
    #ec4899 #64748b
  )

  @spec colour_presets() :: [String.t()]
  def colour_presets, do: @colour_presets

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> do_save()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    tags_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("toggle_tag_selection", %{"name" => tag_name}, socket) do
    selected = socket.assigns.tags_editor.selected

    next_selected =
      if tag_name in selected do
        Enum.reject(selected, &(&1 == tag_name))
      else
        selected ++ [tag_name]
      end

    socket =
      socket
      |> put_in_tags_editor([:selected], next_selected)
      |> maybe_seed_edit_draft(socket.assigns.project_id, next_selected)

    {:noreply, socket}
  end

  def handle_event("change_new_tag_editor", %{"new_tag" => params}, socket) do
    tags_editor =
      Map.put(socket.assigns.tags_editor, :new_tag, %{
        "name" => Map.get(params, "name", ""),
        "color" => Map.get(params, "color", "")
      })

    {:noreply, assign(socket, :tags_editor, tags_editor)}
  end

  def handle_event("create_tag_editor", _params, socket) do
    project_id = socket.assigns.project_id
    draft = socket.assigns.tags_editor.new_tag

    case Tags.create_tag(%{
           project_id: project_id,
           name: Map.get(draft, "name"),
           color: blank_to_nil(Map.get(draft, "color"))
         }) do
      {:ok, _tag} ->
        notify_parent(:tags_changed)

        socket
        |> put_in_tags_editor([:new_tag], %{"name" => "", "color" => ""})
        |> load_data()
        |> noreply()

      {:error, reason} ->
        notify_output(dgettext("ui", "Tags"), inspect(reason), "error")
        {:noreply, socket}
    end
  end

  def handle_event("change_edit_tag_editor", %{"edit_tag" => params}, socket) do
    tags_editor =
      Map.put(socket.assigns.tags_editor, :edit_draft, %{
        "name" => Map.get(params, "name", ""),
        "color" => Map.get(params, "color", ""),
        "post_template_slug" => Map.get(params, "post_template_slug", "")
      })

    {:noreply, assign(socket, :tags_editor, tags_editor)}
  end

  def handle_event("pick_new_tag_color", %{"color" => color}, socket) do
    tags_editor =
      Map.put(socket.assigns.tags_editor, :new_tag, %{
        socket.assigns.tags_editor.new_tag
        | "color" => color
      })

    {:noreply, assign(socket, :tags_editor, tags_editor)}
  end

  def handle_event("pick_edit_tag_color", %{"color" => color}, socket) do
    tags_editor =
      Map.put(socket.assigns.tags_editor, :edit_draft, %{
        socket.assigns.tags_editor.edit_draft
        | "color" => color
      })

    {:noreply, assign(socket, :tags_editor, tags_editor)}
  end

  def handle_event("save_tag_editor", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("delete_tag_editor", _params, socket) do
    case socket.assigns.tags_editor.selected do
      [tag_name] ->
        project_id = socket.assigns.project_id

        case Repo.get_by(Tag, project_id: project_id, name: tag_name) do
          nil ->
            {:noreply, socket}

          %Tag{id: tag_id} ->
            counts = tag_counts(project_id)
            post_count = Map.get(counts, tag_name, 0)
            Notify.parent({:confirm_tag_delete, tag_id, tag_name, post_count})
            {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("change_merge_target", %{"target" => target}, socket) do
    tags_editor =
      Map.put(socket.assigns.tags_editor, :merge_target, to_string(target || ""))

    {:noreply, assign(socket, :tags_editor, tags_editor)}
  end

  def handle_event("merge_tags_editor", _params, socket) do
    selected = socket.assigns.tags_editor.selected
    target_name = socket.assigns.tags_editor.merge_target

    cond do
      length(selected) < 2 or target_name == "" ->
        {:noreply, socket}

      true ->
        project_id = socket.assigns.project_id

        tags =
          Repo.all(
            from tag in Tag, where: tag.project_id == ^project_id and tag.name in ^selected
          )

        target = Enum.find(tags, &(&1.name == target_name))
        sources = Enum.reject(tags, &(&1.name == target_name))

        case target do
          nil ->
            {:noreply, socket}

          _target ->
            case Tags.merge_tags(Enum.map(sources, & &1.id), target.id) do
              {:ok, _merged} ->
                notify_parent(:tags_changed)

                socket
                |> put_in_tags_editor([:selected], [target.name])
                |> put_in_tags_editor([:merge_target], target.name)
                |> maybe_seed_edit_draft(project_id, [target.name])
                |> load_data()
                |> noreply()

              {:error, reason} ->
                notify_output(dgettext("ui", "Tags"), inspect(reason), "error")
                {:noreply, socket}
            end
        end
    end
  end

  def handle_event("sync_tags_editor", _params, socket) do
    case Tags.sync_tags_from_posts(socket.assigns.project_id) do
      {:ok, _tags} ->
        notify_parent(:tags_changed)
        {:noreply, load_data(socket)}

      {:error, reason} ->
        notify_output(dgettext("ui", "Tags"), inspect(reason), "error")
        {:noreply, socket}
    end
  end

  defp do_save(socket) do
    selected = socket.assigns.tags_editor.selected
    draft = socket.assigns.tags_editor.edit_draft
    project_id = socket.assigns.project_id

    case selected do
      [tag_name] ->
        case Repo.get_by(Tag, project_id: project_id, name: tag_name) do
          nil ->
            socket

          %Tag{} = tag ->
            with {:ok, _updated_tag} <-
                   Tags.update_tag(tag.id, %{
                     color: blank_to_nil(Map.get(draft, "color")),
                     post_template_slug: blank_to_nil(Map.get(draft, "post_template_slug"))
                   }),
                 {:ok, renamed_tag} <- maybe_rename_tag(tag, Map.get(draft, "name", tag.name)) do
              notify_parent(:tags_changed)

              socket
              |> put_in_tags_editor([:selected], [renamed_tag.name])
              |> maybe_seed_edit_draft(project_id, [renamed_tag.name])
              |> load_data()
            else
              {:error, reason} ->
                notify_output(dgettext("ui", "Tags"), inspect(reason), "error")
                socket
            end
        end

      _other ->
        socket
    end
  end

  attr(:color, :string, default: nil)
  attr(:presets, :list, required: true)
  attr(:pick_event, :string, required: true)
  attr(:target, :any, required: true)

  defp colour_picker(assigns) do
    ~H"""
    <div
      class="colour-picker-wrap"
      id={"cp-#{@pick_event}"}
      phx-hook="ColourPicker"
      data-pick-event={@pick_event}
      data-target={if @target, do: @target.cid}
    >
      <button
        type="button"
        class="colour-picker-trigger"
        style={"background-color: #{if @color in [nil, ""], do: "#3b82f6", else: @color}"}
        phx-click={Phoenix.LiveView.JS.toggle(to: "#cp-#{@pick_event} .colour-picker-popover")}
      />
      <div class="colour-picker-popover hidden">
        <div class="colour-picker-grid">
          <%= for preset <- @presets do %>
            <button
              type="button"
              class={"colour-picker-swatch#{if normalize_hex(@color) == normalize_hex(preset), do: " selected", else: ""}"}
              style={"background-color: #{preset}"}
              phx-click={Phoenix.LiveView.JS.push(@pick_event, value: %{color: preset}, target: if(@target, do: @target.cid)) |> Phoenix.LiveView.JS.add_class("hidden", to: "#cp-#{@pick_event} .colour-picker-popover")}
            />
          <% end %>
        </div>
        <div class="colour-picker-custom">
          <label>#</label>
          <input
            type="text"
            maxlength="7"
            placeholder="RRGGBB"
            value={if @color in [nil, ""], do: "", else: @color}
          />
        </div>
      </div>
    </div>
    """
  end

  defp normalize_hex(nil), do: nil
  defp normalize_hex(""), do: nil
  defp normalize_hex(hex), do: String.downcase(hex)

  defp load_data(socket) do
    project_id = socket.assigns.project_id

    tags =
      Repo.all(from tag in Tag, where: tag.project_id == ^project_id, order_by: [asc: tag.name])

    counts = tag_counts(project_id)
    selected = Map.get(socket.assigns, :tags_editor, %{}) |> Map.get(:selected, [])

    edit_tag =
      if length(selected) == 1, do: Enum.find(tags, &(&1.name == hd(selected))), else: nil

    edit_draft =
      Map.get(socket.assigns, :tags_editor, %{}) |> Map.get(:edit_draft, edit_draft(edit_tag))

    templates =
      Repo.all(
        from template in Template,
          where: template.project_id == ^project_id,
          order_by: [asc: template.title],
          select: %{slug: template.slug, title: template.title}
      )

    selected_section = current_tags_section(socket.assigns)

    data = %{
      tags:
        Enum.map(tags, fn tag ->
          %{name: tag.name, color: tag.color, count: Map.get(counts, tag.name, 0)}
        end),
      selected: selected,
      new_tag:
        Map.get(socket.assigns, :tags_editor, %{})
        |> Map.get(:new_tag, %{"name" => "", "color" => ""}),
      edit_draft: edit_draft,
      templates: templates,
      merge_target:
        Map.get(socket.assigns, :tags_editor, %{})
        |> Map.get(:merge_target, List.first(selected) || ""),
      selected_section: selected_section,
      colour_presets: @colour_presets
    }

    assign(socket, :tags_editor, data)
  end

  defp put_in_tags_editor(socket, [key], value) do
    assign(socket, :tags_editor, Map.put(socket.assigns.tags_editor, key, value))
  end

  defp noreply(socket), do: {:noreply, socket}

  defp notify_parent(message) do
    Notify.parent(message)
  end

  defp notify_output(title, message, level) do
    Notify.output(title, message, level)
  end

  @spec tag_font_size(term(), term()) :: term()
  def tag_font_size(count, counts) do
    max_count = Enum.max([1 | Enum.map(counts, & &1.count)])
    ratio = if max_count <= 1, do: 0.0, else: (count - 1) / max(max_count - 1, 1)
    Float.round(0.85 + (1.8 - 0.85) * ratio, 2)
  end

  @spec tag_style(term(), term()) :: term()
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

  defp maybe_seed_edit_draft(socket, project_id, [tag_name]) do
    case Repo.get_by(Tag, project_id: project_id, name: tag_name) do
      %Tag{} = tag ->
        put_in_tags_editor(socket, [:edit_draft], edit_draft(tag))

      _other ->
        put_in_tags_editor(socket, [:edit_draft], %{})
    end
  end

  defp maybe_seed_edit_draft(socket, _project_id, _selected),
    do: put_in_tags_editor(socket, [:edit_draft], %{})

  defp edit_draft(nil), do: %{}

  defp edit_draft(%Tag{} = tag),
    do: %{
      "name" => tag.name,
      "color" => tag.color || "",
      "post_template_slug" => tag.post_template_slug || ""
    }

  defp maybe_rename_tag(%Tag{} = tag, next_name) do
    normalized = String.trim(to_string(next_name || tag.name))

    if normalized == tag.name do
      {:ok, tag}
    else
      Tags.rename_tag(tag.id, normalized)
    end
  end

  defp current_tags_section(assigns) do
    assigns
    |> current_tab_meta()
    |> Map.get(:sidebar_item_id, "tags-cloud")
    |> to_string()
    |> String.replace_prefix("tags-", "")
    |> case do
      section when section in @tags_sections -> section
      _other -> "cloud"
    end
  end

  defp current_tab_meta(%{current_tab: %{type: type, id: id}, tab_meta: tab_meta}) do
    Map.get(tab_meta || %{}, {type, id}, %{})
  end

  defp current_tab_meta(_assigns), do: %{}

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
