defmodule BDS.Desktop.ShellLive.PostEditor.DraftManagement do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Posts
  alias BDS.Posts.{Post, Translation}
  alias BDS.Desktop.ShellLive.PostEditor.PostMetadata
  alias BDS.UI.Workbench

  @spec normalize_mode(term()) :: term()
  def normalize_mode(mode) when mode in [:markdown, :preview], do: mode
  @spec normalize_mode(term()) :: term()
  def normalize_mode("visual"), do: :markdown
  def normalize_mode("preview"), do: :preview
  def normalize_mode(_mode), do: :markdown

  @spec normalize_language(term(), term()) :: term()
  def normalize_language(value, fallback) do
    case value |> to_string() |> String.trim() do
      "" -> fallback
      normalized -> String.downcase(normalized)
    end
  end

  @spec normalize_params(term(), term(), term()) :: term()
  def normalize_params(params, current_language, next_language) do
    %{
      "title" => Map.get(params, "title", ""),
      "excerpt" => Map.get(params, "excerpt", ""),
      "content" => Map.get(params, "content", ""),
      "tags" => Map.get(params, "tags", ""),
      "categories" => Map.get(params, "categories", ""),
      "author" => Map.get(params, "author", ""),
      "language" =>
        if(current_language == next_language,
          do: normalize_language(Map.get(params, "language"), current_language),
          else: next_language
        ),
      "do_not_translate" => truthy?(Map.get(params, "do_not_translate")),
      "template_slug" => Map.get(params, "template_slug", "")
    }
  end

  @spec current_draft(term(), term(), term(), term()) :: term()
  def current_draft(assigns, %Post{} = post, metadata, active_language) do
    persisted = persisted_form(post, metadata, active_language)

    assigns.post_editor_drafts
    |> Map.get(post.id, %{})
    |> Map.get(active_language, persisted)
  end

  @spec persisted_form(term(), term(), term()) :: term()
  def persisted_form(%Post{} = post, metadata, active_language) do
    persisted_form(post, metadata, active_language, PostMetadata.translations(post.id))
  end

  @spec persisted_form(term(), term(), term(), term()) :: term()
  def persisted_form(post, metadata, active_language, translations) do
    canonical_language = PostMetadata.canonical_language(post, metadata)
    translation = Map.get(translations, active_language)

    if active_language == canonical_language do
      %{
        "title" => post.title || "",
        "excerpt" => post.excerpt || "",
        "content" => Posts.editor_body(post),
        "tags" => Enum.join(post.tags || [], ", "),
        "categories" => Enum.join(post.categories || [], ", "),
        "author" => post.author || metadata.default_author || "",
        "language" => canonical_language,
        "do_not_translate" => post.do_not_translate || false,
        "template_slug" => post.template_slug || ""
      }
    else
      %{
        "title" => (translation && translation.title) || "",
        "excerpt" => (translation && translation.excerpt) || "",
        "content" => if(translation, do: Posts.editor_body(translation), else: ""),
        "tags" => Enum.join(post.tags || [], ", "),
        "categories" => Enum.join(post.categories || [], ", "),
        "author" => post.author || metadata.default_author || "",
        "language" => active_language,
        "do_not_translate" => post.do_not_translate || false,
        "template_slug" => post.template_slug || ""
      }
    end
  end

  @spec maybe_update_draft(term(), term(), term(), term(), term(), term(), term()) :: term()
  def maybe_update_draft(socket, post_id, post, current_language, next_language, draft, true) do
    workbench = Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)

    socket
    |> assign(:workbench, workbench)
    |> assign(
      :post_editor_drafts,
      put_nested_map(socket.assigns.post_editor_drafts, post_id, next_language, draft)
    )
    |> assign(
      :post_editor_active_languages,
      Map.put(socket.assigns.post_editor_active_languages, post_id, next_language)
    )
    |> assign(
      :post_editor_save_states,
      Map.put(socket.assigns.post_editor_save_states, post_id, :dirty)
    )
    |> assign(
      :tab_meta,
      Map.put(socket.assigns.tab_meta, {:post, post_id}, %{
        title: draft["title"],
        subtitle: Atom.to_string(post.status || :draft)
      })
    )
    |> maybe_drop_old_language_draft(post_id, current_language, next_language)
  end

  def maybe_update_draft(socket, post_id, _post, _current_language, next_language, _draft, false) do
    assign(
      socket,
      :post_editor_active_languages,
      Map.put(socket.assigns.post_editor_active_languages, post_id, next_language)
    )
  end

  @spec put_draft_field(term(), term(), term(), term(), term(), term()) :: term()
  def put_draft_field(socket, post_id, post, active_language, field, value) do
    metadata = PostMetadata.project_metadata(post.project_id)
    draft = Map.put(current_draft(socket.assigns, post, metadata, active_language), field, value)
    workbench = Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)

    socket
    |> assign(:workbench, workbench)
    |> assign(
      :post_editor_drafts,
      put_nested_map(socket.assigns.post_editor_drafts, post_id, active_language, draft)
    )
    |> assign(
      :post_editor_save_states,
      Map.put(socket.assigns.post_editor_save_states, post_id, :dirty)
    )
  end

  @spec put_query_state(term(), term(), term(), term()) :: term()
  def put_query_state(socket, post_id, kind, value) do
    key = query_key(kind)

    assign(
      socket,
      key,
      Map.put(Map.get(socket.assigns, key, %{}), post_id, to_string(value || ""))
    )
  end

  @spec query_value(term(), term(), term()) :: term()
  def query_value(assigns, kind, post_id) do
    assigns
    |> Map.get(query_key(kind), %{})
    |> Map.get(post_id, "")
  end

  defp query_key(:tags), do: :post_editor_tag_queries
  defp query_key(:categories), do: :post_editor_category_queries

  defp maybe_drop_old_language_draft(socket, _post_id, current_language, next_language)
       when current_language == next_language,
       do: socket

  defp maybe_drop_old_language_draft(socket, post_id, current_language, _next_language) do
    assign(
      socket,
      :post_editor_drafts,
      delete_nested_map(socket.assigns.post_editor_drafts, post_id, current_language)
    )
  end

  @spec toggled_sections(term(), term(), term()) :: term()
  def toggled_sections(expanded_by_post, post_id, section) do
    expanded_by_post
    |> Map.get(post_id, %{metadata: false, excerpt: false})
    |> Map.put_new(:metadata, false)
    |> Map.put_new(:excerpt, false)
    |> Map.update!(section, &(not &1))
  end

  @spec put_nested_map(term(), term(), term(), term()) :: term()
  def put_nested_map(map, key, nested_key, value) do
    Map.update(map, key, %{nested_key => value}, &Map.put(&1, nested_key, value))
  end

  @spec delete_nested_map(term(), term(), term()) :: term()
  def delete_nested_map(map, key, nested_key) do
    case Map.get(map, key) do
      nil ->
        map

      nested ->
        case Map.delete(nested, nested_key) do
          emptied when map_size(emptied) == 0 -> Map.delete(map, key)
          remaining -> Map.put(map, key, remaining)
        end
    end
  end

  @spec reload_with_assigned_workbench(term(), term()) :: term()
  def reload_with_assigned_workbench(socket, reload),
    do: reload.(socket, socket.assigns.workbench)

  @spec save_state_for_action(term()) :: term()
  def save_state_for_action(:publish), do: :published
  def save_state_for_action(_action), do: :saved

  @spec record_title(term(), term()) :: term()
  def record_title(%Translation{title: title}, post),
    do: blank_to_nil(title) || post.title || post.slug || post.id

  def record_title(%Post{title: title, slug: slug, id: id}, _post),
    do: blank_to_nil(title) || blank_to_nil(slug) || id

  @spec record_status(term()) :: term()
  def record_status(%Translation{status: status}), do: status || :draft
  def record_status(%Post{status: status}), do: status || :draft

  @spec editing_canonical_language?(term(), term(), term()) :: term()
  def editing_canonical_language?(translations, active_language, canonical_language) do
    active_language == canonical_language or not Map.has_key?(translations, active_language)
  end

  defp truthy?(value) when value in [true, "true", "on", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
