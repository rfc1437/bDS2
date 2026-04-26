defmodule BDS.Desktop.ShellLive.PostEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.ShellData
  alias BDS.{AI, I18n, Metadata, PostLinks, Posts, Preview, Repo, Tags, Templates}
  alias BDS.Media.Media
  alias BDS.Posts.{Post, Translation}
  alias BDS.UI.Workbench

  embed_templates "post_editor_html/*"

  def assign_socket(socket) do
    assigns = Map.put(socket.assigns, :project_metadata, project_metadata(socket.assigns.projects.active_project_id))
    assign(socket, :post_editor, build(assigns))
  end

  def update(socket, params, reload) do
    case socket.assigns.current_tab do
      %{type: :post, id: post_id} ->
        case Repo.get(Post, post_id) do
          nil ->
            socket

          %Post{} = post ->
            metadata = project_metadata(post.project_id)
            canonical_language = canonical_language(post, metadata)
            current_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
            requested_language = normalize_language(Map.get(params, "language"), current_language)

            next_language =
              if current_language == canonical_language do
                requested_language
              else
                current_language
              end

            draft = normalize_params(params, current_language, next_language)
            current = current_draft(socket.assigns, post, metadata, next_language)
            dirty? = draft != current

            socket
            |> put_query_state(post_id, :tags, Map.get(params, "tag_query", ""))
            |> put_query_state(post_id, :categories, Map.get(params, "category_query", ""))
            |> maybe_update_draft(post_id, post, current_language, next_language, draft, dirty?)
            |> reload_with_assigned_workbench(reload)
        end

      _other ->
        socket
    end
  end

  def persist_socket(socket, post_id, action, reload, append_output) do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = project_metadata(post.project_id)
        canonical_language = canonical_language(post, metadata)
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
        draft = current_draft(socket.assigns, post, metadata, active_language)

        case persist(post, draft, active_language, metadata, action) do
          {:ok, record} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :post, post_id)
            normalized_form = persisted_form(Repo.get!(Post, post_id), metadata, active_language)

            socket
            |> assign(:workbench, workbench)
            |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, active_language, normalized_form))
            |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, save_state_for_action(action)))
            |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: record_title(record, Repo.get!(Post, post_id)), subtitle: Atom.to_string(record_status(record))}))
            |> reload.(workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Post"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def discard_socket(socket, post_id, reload, append_output) do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = project_metadata(post.project_id)
        canonical_language = canonical_language(post, metadata)
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)

        case discard(post, active_language, metadata) do
          {:ok, restored_post} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :post, post_id)

            socket
            |> assign(:workbench, workbench)
            |> assign(:post_editor_drafts, delete_nested_map(socket.assigns.post_editor_drafts, post_id, active_language))
            |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :discarded))
            |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: restored_post.title || restored_post.slug || restored_post.id, subtitle: Atom.to_string(restored_post.status || :draft)}))
            |> reload.(workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Post"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def delete_socket(socket, post_id, reload, append_output) do
    case Posts.delete_post(post_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :post, post_id)

        socket
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:post, post_id}))
        |> assign(:post_editor_drafts, Map.delete(socket.assigns.post_editor_drafts, post_id))
        |> assign(:post_editor_active_languages, Map.delete(socket.assigns.post_editor_active_languages, post_id))
        |> assign(:post_editor_tag_queries, Map.delete(socket.assigns.post_editor_tag_queries, post_id))
        |> assign(:post_editor_category_queries, Map.delete(socket.assigns.post_editor_category_queries, post_id))
        |> assign(:post_editor_quick_actions_open, Map.delete(socket.assigns.post_editor_quick_actions_open, post_id))
        |> assign(:post_editor_modes, Map.delete(socket.assigns.post_editor_modes, post_id))
        |> assign(:post_editor_expanded, Map.delete(socket.assigns.post_editor_expanded, post_id))
        |> assign(:post_editor_save_states, Map.delete(socket.assigns.post_editor_save_states, post_id))
        |> reload.(workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Post"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def set_mode(socket, post_id, mode, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(:post_editor_modes, Map.put(socket.assigns.post_editor_modes, post_id, normalize_mode(mode)))
    |> reload.(workbench)
  end

  def toggle_section(socket, post_id, section, reload) when section in [:metadata, :excerpt] do
    workbench = socket.assigns.workbench

    socket
    |> assign(:post_editor_expanded, Map.put(socket.assigns.post_editor_expanded, post_id, toggled_sections(socket.assigns.post_editor_expanded, post_id, section)))
    |> reload.(workbench)
  end

  def select_language(socket, post_id, language, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(:post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, normalize_language(language, language)))
    |> reload.(workbench)
  end

  def toggle_quick_actions(socket, post_id, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(:post_editor_quick_actions_open, Map.update(socket.assigns.post_editor_quick_actions_open, post_id, true, &(!&1)))
    |> reload.(workbench)
  end

  def detect_language(socket, post_id, reload, append_output) do
    if Map.get(socket.assigns, :offline_mode, true) do
      socket
      |> append_output.(translated("Detect Language"), translated("Automatic AI actions stay gated by airplane mode."), nil, "info")
      |> reload.(socket.assigns.workbench)
    else
      case Repo.get(Post, post_id) do
        nil ->
          socket

        %Post{} = post ->
          metadata = project_metadata(post.project_id)
          canonical_language = canonical_language(post, metadata)
          active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
          draft = current_draft(socket.assigns, post, metadata, active_language)
          text = Enum.join([Map.get(draft, "title", ""), Map.get(draft, "content", "")], "\n\n")

          case AI.detect_language(text) do
            {:ok, %{language_code: language_code}} when is_binary(language_code) and language_code != "" ->
              socket
              |> put_draft_field(post_id, post, active_language, "language", normalize_language(language_code, canonical_language))
              |> reload_with_assigned_workbench(reload)

            {:error, reason} ->
              socket
              |> append_output.(translated("Detect Language"), inspect(reason), nil, "error")
              |> reload.(socket.assigns.workbench)

            _other ->
              socket
              |> append_output.(translated("Detect Language"), translated("Language detection failed."), nil, "error")
              |> reload.(socket.assigns.workbench)
          end
      end
    end
  end

  def translate(socket, post_id, language, reload, append_output) do
    if Map.get(socket.assigns, :offline_mode, true) do
      socket
      |> append_output.(translated("Translate"), translated("Automatic AI actions stay gated by airplane mode."), nil, "info")
      |> reload.(socket.assigns.workbench)
    else
      normalized_language = normalize_language(language, "")

      case AI.translate_post(post_id, normalized_language) do
        {:ok, translation} ->
          with {:ok, _saved_translation} <-
                 Posts.upsert_post_translation(post_id, normalized_language, %{
                   title: translation.title,
                   excerpt: translation.excerpt,
                   content: translation.content
                 }) do
            socket
            |> assign(:post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, normalized_language))
            |> assign(:post_editor_drafts, delete_nested_map(socket.assigns.post_editor_drafts, post_id, normalized_language))
            |> assign(:post_editor_quick_actions_open, Map.put(socket.assigns.post_editor_quick_actions_open, post_id, false))
            |> reload.(socket.assigns.workbench)
          else
            {:error, reason} ->
              socket
              |> append_output.(translated("Translate"), inspect(reason), nil, "error")
              |> reload.(socket.assigns.workbench)
          end

        {:error, reason} ->
          socket
          |> append_output.(translated("Translate"), inspect(reason), nil, "error")
          |> reload.(socket.assigns.workbench)
      end
    end
  end

  def apply_ai_suggestions(socket, post_id, fields, reload, append_output) do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} ->
        attrs =
          fields
          |> Enum.reduce(%{}, fn field, acc ->
            case field.key do
              "title" -> Map.put(acc, :title, blank_to_nil(field.suggested_value))
              "excerpt" -> Map.put(acc, :excerpt, blank_to_nil(field.suggested_value))
              "slug" -> Map.put(acc, :slug, blank_to_nil(field.suggested_value))
              _other -> acc
            end
          end)

        if map_size(attrs) == 0 do
          socket |> assign(:shell_overlay, nil)
        else
          case Posts.update_post(post_id, attrs) do
            {:ok, updated_post} ->
              metadata = project_metadata(updated_post.project_id)
              active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language(updated_post, metadata))
              refreshed_form = persisted_form(updated_post, metadata, active_language)

              socket
              |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, active_language, refreshed_form))
              |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :dirty))
              |> assign(:shell_overlay, nil)
              |> reload.(socket.assigns.workbench)

            {:error, reason} ->
              socket
              |> append_output.(translated("AI Suggestions"), inspect(reason), nil, "error")
              |> reload.(socket.assigns.workbench)
          end
        end
    end
  end

  def insert_content(socket, post_id, snippet, reload) do
    socket
    |> Phoenix.LiveView.push_event("post-editor-insert-content", %{id: post_id, content: snippet})
    |> assign(:shell_overlay, nil)
    |> reload.(socket.assigns.workbench)
  end

  def add_list_value(socket, post_id, kind, value, reload) when kind in [:tags, :categories] do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = project_metadata(post.project_id)
        canonical_language = canonical_language(post, metadata)
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
        draft = current_draft(socket.assigns, post, metadata, active_language)
        normalized = normalize_list_entry(value)

        if normalized == "" do
          socket
        else
          ensure_list_value(post.project_id, kind, normalized)

          updated =
            draft
            |> Map.get(field_key(kind), "")
            |> csv_to_list()
            |> Kernel.++([normalized])
            |> Enum.uniq()
            |> Enum.join(", ")

          socket
          |> put_query_state(post_id, kind, "")
          |> put_draft_field(post_id, post, active_language, field_key(kind), updated)
          |> reload_with_assigned_workbench(reload)
        end
    end
  end

  def remove_list_value(socket, post_id, kind, value, reload) when kind in [:tags, :categories] do
    case Repo.get(Post, post_id) do
      nil ->
        socket

      %Post{} = post ->
        metadata = project_metadata(post.project_id)
        canonical_language = canonical_language(post, metadata)
        active_language = Map.get(socket.assigns.post_editor_active_languages, post_id, canonical_language)
        draft = current_draft(socket.assigns, post, metadata, active_language)
        updated = draft |> Map.get(field_key(kind), "") |> csv_to_list() |> Enum.reject(&(&1 == value)) |> Enum.join(", ")

        socket
        |> put_draft_field(post_id, post, active_language, field_key(kind), updated)
        |> reload_with_assigned_workbench(reload)
    end
  end

  def build(%{current_tab: %{type: :post, id: post_id}} = assigns) do
    case Repo.get(Post, post_id) do
      nil ->
        nil

      %Post{} = post ->
        metadata = assigned_project_metadata(assigns)
        canonical_language = canonical_language(post, metadata)
        active_language = Map.get(assigns.post_editor_active_languages, post.id, canonical_language)
        translations = translations(post.id)
        persisted_form = persisted_form(post, metadata, active_language, translations)

        form =
          assigns.post_editor_drafts
          |> Map.get(post.id, %{})
          |> Map.get(active_language, persisted_form)

        expanded =
          Map.get(assigns.post_editor_expanded, post.id, %{
            metadata: blank?(post.title),
            excerpt: not blank?(post.excerpt)
          })

        current_translation = Map.get(translations, active_language)

        %{
          id: post.id,
          display_title: display_title(form["title"], post.slug, post.id),
          subtitle: nil,
          slug: post.slug || post.id,
          status: post.status || :draft,
          dirty?: Workbench.dirty?(assigns.workbench, :post, post.id),
          save_state: Map.get(assigns.post_editor_save_states, post.id, :idle),
          quick_actions_open?: Map.get(assigns.post_editor_quick_actions_open, post.id, false),
          metadata_expanded: Map.get(expanded, :metadata, false),
          excerpt_expanded: Map.get(expanded, :excerpt, false),
          mode: Map.get(assigns.post_editor_modes, post.id, :markdown),
          editing_canonical?: editing_canonical_language?(translations, active_language, canonical_language),
          can_publish?: (post.status || :draft) == :draft,
          can_delete?: (post.status || :draft) == :published,
          has_published_version?: has_published_version?(post),
          discard_label: discard_label(post),
          discard_title: discard_title(post),
          detect_language_enabled?: not blank?(Map.get(form, "title")) or not blank?(Map.get(form, "content")),
          can_translate?: Enum.any?(languages(metadata), &(&1 != canonical_language)),
          languages: languages(metadata),
          form: form,
          template_options: template_options(post.project_id),
          show_template_selector?: template_options(post.project_id) != [],
          tag_options: Tags.list_tags(post.project_id),
          tag_values: tag_values(form),
          tag_chips: tag_chips(form, Tags.list_tags(post.project_id)),
          tag_query: query_value(assigns, :tags, post.id),
          tag_query_addable?: query_addable?(query_value(assigns, :tags, post.id), tag_values(form), Tags.list_tags(post.project_id), fn option -> option.name end),
          category_values: category_values(form),
          category_query: query_value(assigns, :categories, post.id),
          category_options: metadata.categories || [],
          category_query_addable?: query_addable?(query_value(assigns, :categories, post.id), category_values(form), metadata.categories || [], & &1),
          tag_suggestions: tag_suggestions(form, Tags.list_tags(post.project_id), query_value(assigns, :tags, post.id)),
          category_suggestions: category_suggestions(form, metadata.categories || [], query_value(assigns, :categories, post.id)),
          gallery_count: gallery_count(form),
          preview_url: preview_url(post, active_language, canonical_language, Map.get(assigns.post_editor_modes, post.id, :markdown)),
          translation_flags: translation_flags(post, canonical_language, active_language, translations),
          linked_media: linked_media(post.id),
          post_links: post_links(post.id),
          footer: footer(post, current_translation, active_language, canonical_language)
        }
    end
  end

  def build(_assigns), do: nil

  def normalize_mode(mode) when mode in [:markdown, :preview], do: mode
  def normalize_mode("visual"), do: :markdown
  def normalize_mode("preview"), do: :preview
  def normalize_mode(_mode), do: :markdown

  def normalize_language(value, fallback) do
    case value |> to_string() |> String.trim() do
      "" -> fallback
      normalized -> String.downcase(normalized)
    end
  end

  def normalize_params(params, current_language, next_language) do
    %{
      "title" => Map.get(params, "title", ""),
      "excerpt" => Map.get(params, "excerpt", ""),
      "content" => Map.get(params, "content", ""),
      "tags" => Map.get(params, "tags", ""),
      "categories" => Map.get(params, "categories", ""),
      "author" => Map.get(params, "author", ""),
      "language" => if(current_language == next_language, do: normalize_language(Map.get(params, "language"), current_language), else: next_language),
      "do_not_translate" => truthy?(Map.get(params, "do_not_translate")),
      "template_slug" => Map.get(params, "template_slug", "")
    }
  end

  def current_draft(assigns, %Post{} = post, metadata, active_language) do
    persisted = persisted_form(post, metadata, active_language)

    assigns.post_editor_drafts
    |> Map.get(post.id, %{})
    |> Map.get(active_language, persisted)
  end

  def persisted_form(%Post{} = post, metadata, active_language) do
    persisted_form(post, metadata, active_language, translations(post.id))
  end

  def persist(%Post{} = post, draft, active_language, metadata, action) do
    canonical_language = canonical_language(post, metadata)
    translations = translations(post.id)

    result =
      if editing_canonical_language?(translations, active_language, canonical_language) do
        post
        |> save_canonical_draft(draft)
        |> maybe_publish_post(post.id, action)
      else
        post.id
        |> save_translation_draft(active_language, draft)
        |> maybe_publish_translation(post.id, active_language, action)
      end

    result
  end

  def discard(%Post{} = post, active_language, metadata) do
    canonical_language = canonical_language(post, metadata)
    current_translations = translations(post.id)

    cond do
      not editing_canonical_language?(current_translations, active_language, canonical_language) ->
        {:ok, post}

      post.file_path not in [nil, ""] and post.status == :draft ->
        Posts.discard_post_changes(post.id)

      true ->
        {:ok, post}
    end
  end

  def save_state_for_action(:publish), do: :published
  def save_state_for_action(_action), do: :saved

  def record_title(%Translation{title: title}, post), do: blank_to_nil(title) || post.title || post.slug || post.id
  def record_title(%Post{title: title, slug: slug, id: id}, _post), do: blank_to_nil(title) || blank_to_nil(slug) || id

  def record_status(%Translation{status: status}), do: status || :draft
  def record_status(%Post{status: status}), do: status || :draft

  def editing_canonical_language?(translations, active_language, canonical_language) do
    active_language == canonical_language or not Map.has_key?(translations, active_language)
  end

  def post_status_label(status), do: ShellData.dashboard_status_label(status)

  def post_editor_save_state_label(:dirty), do: translated("Unsaved")
  def post_editor_save_state_label(:saved), do: translated("Saved")
  def post_editor_save_state_label(:published), do: translated("Published")
  def post_editor_save_state_label(:discarded), do: translated("Reverted")
  def post_editor_save_state_label(_state), do: translated("Idle")

  def post_editor_mode_label(:markdown), do: translated("Markdown")
  def post_editor_mode_label(:preview), do: translated("Preview")

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  def ai_overlay_fields(selected), do: Enum.filter(selected, & &1.accepted)

  def project_metadata(nil), do: %{main_language: "en", blog_languages: []}

  def project_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    metadata
  rescue
    _error -> %{main_language: "en", blog_languages: []}
  end

  def tag_chip_style(nil), do: nil

  def tag_chip_style(color) do
    normalized = normalize_color(color)

    if normalized do
      "background-color: #{normalized}; color: #{contrast_color(normalized)}; border-color: #{normalized};"
    end
  end

  defp assigned_project_metadata(assigns), do: Map.get(assigns, :project_metadata, %{})

  defp maybe_update_draft(socket, post_id, post, current_language, next_language, draft, true) do
    workbench = Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)

    socket
    |> assign(:workbench, workbench)
    |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, next_language, draft))
    |> assign(:post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, next_language))
    |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :dirty))
    |> assign(:tab_meta, Map.put(socket.assigns.tab_meta, {:post, post_id}, %{title: draft["title"], subtitle: Atom.to_string(post.status || :draft)}))
    |> maybe_drop_old_language_draft(post_id, current_language, next_language)
  end

  defp maybe_update_draft(socket, post_id, _post, _current_language, next_language, _draft, false) do
    assign(socket, :post_editor_active_languages, Map.put(socket.assigns.post_editor_active_languages, post_id, next_language))
  end

  defp put_draft_field(socket, post_id, post, active_language, field, value) do
    metadata = project_metadata(post.project_id)
    draft = Map.put(current_draft(socket.assigns, post, metadata, active_language), field, value)
    workbench = Workbench.mark_dirty(socket.assigns.workbench, :post, post_id)

    socket
    |> assign(:workbench, workbench)
    |> assign(:post_editor_drafts, put_nested_map(socket.assigns.post_editor_drafts, post_id, active_language, draft))
    |> assign(:post_editor_save_states, Map.put(socket.assigns.post_editor_save_states, post_id, :dirty))
  end

  defp put_query_state(socket, post_id, kind, value) do
    key = query_key(kind)
    assign(socket, key, Map.put(Map.get(socket.assigns, key, %{}), post_id, to_string(value || "")))
  end

  defp query_value(assigns, kind, post_id) do
    assigns
    |> Map.get(query_key(kind), %{})
    |> Map.get(post_id, "")
  end

  defp query_key(:tags), do: :post_editor_tag_queries
  defp query_key(:categories), do: :post_editor_category_queries

  defp field_key(:tags), do: "tags"
  defp field_key(:categories), do: "categories"

  defp tag_values(form), do: csv_to_list(Map.get(form, "tags", ""))
  defp category_values(form), do: csv_to_list(Map.get(form, "categories", ""))

  defp tag_suggestions(form, options, query) do
    selected = MapSet.new(tag_values(form))
    filter_suggestions(options, query, fn option -> option.name end, selected)
  end

  defp tag_chips(form, options) do
    option_map = Map.new(options, fn option -> {option.name, option} end)

    Enum.map(tag_values(form), fn name ->
      option = Map.get(option_map, name)
      %{name: name, color: option && option.color}
    end)
  end

  defp category_suggestions(form, options, query) do
    selected = MapSet.new(category_values(form))
    filter_suggestions(options, query, & &1, selected)
  end

  defp filter_suggestions(options, query, labeler, selected) do
    query = normalize_query(query)

    options
    |> Enum.filter(fn option ->
      label = labeler.(option)
      not MapSet.member?(selected, label) and (query == "" or String.contains?(String.downcase(label), query))
    end)
    |> Enum.take(8)
  end

  defp query_addable?(query, selected_values, options, labeler) do
    normalized = normalize_query(query)

    normalized != "" and
      normalized not in Enum.map(selected_values, &String.downcase/1) and
      not Enum.any?(options, fn option -> String.downcase(labeler.(option)) == normalized end)
  end

  defp normalize_query(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_list_entry(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp ensure_list_value(project_id, :tags, value) do
    if Enum.any?(Tags.list_tags(project_id), &(String.downcase(&1.name) == value)) do
      :ok
    else
      _ = Tags.create_tag(%{project_id: project_id, name: value})
      :ok
    end
  end

  defp ensure_list_value(project_id, :categories, value) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    if value in (metadata.categories || []) do
      :ok
    else
      _ = Metadata.add_category(project_id, value)
      :ok
    end
  rescue
    _error -> :ok
  end

  defp normalize_color(nil), do: nil
  defp normalize_color(""), do: nil

  defp normalize_color("#" <> rest = color) when byte_size(rest) == 6 do
    if String.match?(rest, ~r/\A[0-9a-fA-F]{6}\z/), do: color, else: nil
  end

  defp normalize_color(_color), do: nil

  defp contrast_color("#" <> rgb) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = rgb
    {red, _} = Integer.parse(r, 16)
    {green, _} = Integer.parse(g, 16)
    {blue, _} = Integer.parse(b, 16)
    luminance = (red * 299 + green * 587 + blue * 114) / 1000
    if luminance > 150, do: "#1e1e1e", else: "#ffffff"
  end

  defp contrast_color(_color), do: "#ffffff"

  defp reload_with_assigned_workbench(socket, reload), do: reload.(socket, socket.assigns.workbench)

  defp persisted_form(post, metadata, active_language, translations) do
    canonical_language = canonical_language(post, metadata)
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
        "title" => translation && translation.title || "",
        "excerpt" => translation && translation.excerpt || "",
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

  defp canonical_language(post, metadata) do
    normalize_language(post.language, metadata.main_language || "en")
  end

  defp truthy?(value) when value in [true, "true", "on", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp blank?(value), do: blank_to_nil(value) == nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp csv_to_list(value) do
    value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp translations(post_id) do
    {:ok, translations} = Posts.list_post_translations(post_id)
    Map.new(translations, fn translation -> {translation.language, translation} end)
  end

  defp languages(metadata) do
    (([metadata.main_language || "en"] ++ (metadata.blog_languages || [])) ++ Enum.map(I18n.supported_languages(), & &1.code))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp template_options(project_id) do
    Repo.all(
      from template in Templates.Template,
        where: template.project_id == ^project_id,
        order_by: [asc: template.title, asc: template.slug],
        select: %{slug: template.slug, title: fragment("COALESCE(?, ?)", template.title, template.slug)}
    )
  rescue
    _error -> []
  end

  defp linked_media(post_id) do
    case Repo.query("SELECT media_id, sort_order FROM post_media WHERE post_id = ? ORDER BY sort_order ASC, media_id ASC", [post_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [media_id, sort_order] ->
          case Repo.get(Media, media_id) do
            %Media{} = media ->
              %{
                media_id: media.id,
                has_thumbnail: String.starts_with?(to_string(media.mime_type || ""), "image/"),
                name: media.title || media.original_name || media.id,
                sort_order: sort_order || 0
              }

            _other ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp post_links(post_id) do
    %{
      backlinks: related_posts(PostLinks.list_incoming_links(post_id), :source_post_id),
      outlinks: related_posts(PostLinks.list_outgoing_links(post_id), :target_post_id)
    }
  end

  defp related_posts(links, key) do
    Enum.map(links, fn link ->
      case Repo.get(Post, Map.fetch!(link, key)) do
        %Post{} = post -> %{id: post.id, title: post.title || post.slug || post.id, text: link.link_text || post.slug || post.id}
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp translation_flags(post, canonical_language, active_language, translations) do
    canonical = %{language: canonical_language, flag: I18n.flag(canonical_language), status: Atom.to_string(post.status || :draft), active: active_language == canonical_language, label: canonical_language}

    others =
      translations
      |> Map.values()
      |> Enum.sort_by(& &1.language)
      |> Enum.map(fn translation ->
        %{
          language: translation.language,
          flag: I18n.flag(translation.language),
          status: Atom.to_string(translation.status || :draft),
          active: active_language == translation.language,
          label: translation.language
        }
      end)

    [canonical | others]
  end

  defp footer(post, translation, active_language, canonical_language) do
    if active_language == canonical_language do
      %{
        created_at: format_timestamp(post.created_at),
        updated_at: format_timestamp(post.updated_at),
        published_at: format_timestamp(post.published_at)
      }
    else
      %{
        created_at: format_timestamp(translation && translation.created_at || post.created_at),
        updated_at: format_timestamp(translation && translation.updated_at || post.updated_at),
        published_at: format_timestamp(translation && translation.published_at)
      }
    end
  end

  defp format_timestamp(nil), do: ""

  defp format_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%x")
  end

  defp display_title(title, slug, fallback_id) do
    blank_to_nil(title) || blank_to_nil(slug) || fallback_id || translated("Untitled")
  end

  defp has_published_version?(%Post{} = post), do: not is_nil(post.published_at) or post.file_path not in [nil, ""]

  defp discard_label(%Post{} = post) do
    if has_published_version?(post), do: translated("Discard Changes"), else: translated("Discard Draft")
  end

  defp discard_title(%Post{} = post) do
    if has_published_version?(post), do: translated("Discard changes and restore the published version"), else: translated("Delete this unpublished draft")
  end

  defp gallery_count(form) do
    form
    |> Map.get("content", "")
    |> to_string()
    |> then(&Regex.scan(~r/!\[[^\]]*\]\([^\)]+\)/, &1))
    |> length()
  end

  defp preview_url(_post, _active_language, _canonical_language, mode) when mode != :preview, do: nil

  defp preview_url(%Post{} = post, active_language, canonical_language, :preview) do
    with {:ok, server} <- Preview.start_preview(post.project_id) do
      base_url = "http://#{server.host}:#{server.port}"
      query =
        %{}
        |> maybe_put_query("draft", "true")
        |> maybe_put_query("post_id", post.id)
        |> maybe_put_query("lang", active_language != canonical_language && active_language)

      base_url <> canonical_preview_path(post.created_at, post.slug) <> "?" <> URI.encode_query(query)
    else
      _other -> nil
    end
  end

  defp canonical_preview_path(created_at_ms, slug) do
    datetime = DateTime.from_unix!(created_at_ms, :millisecond)
    "/#{datetime.year}/#{pad2(datetime.month)}/#{pad2(datetime.day)}/#{slug || ""}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp maybe_put_query(query, _key, false), do: query
  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp save_canonical_draft(%Post{id: post_id}, draft) do
    Posts.update_post(post_id, %{
      title: blank_to_nil(Map.get(draft, "title")),
      excerpt: blank_to_nil(Map.get(draft, "excerpt")),
      content: blank_to_nil(Map.get(draft, "content")),
      tags: csv_to_list(Map.get(draft, "tags")),
      categories: csv_to_list(Map.get(draft, "categories")),
      author: blank_to_nil(Map.get(draft, "author")),
      language: blank_to_nil(Map.get(draft, "language")),
      do_not_translate: Map.get(draft, "do_not_translate", false),
      template_slug: blank_to_nil(Map.get(draft, "template_slug"))
    })
  end

  defp save_translation_draft(post_id, language, draft) do
    Posts.upsert_post_translation(post_id, language, %{
      title: Map.get(draft, "title", ""),
      excerpt: blank_to_nil(Map.get(draft, "excerpt")),
      content: blank_to_nil(Map.get(draft, "content"))
    })
  end

  defp maybe_publish_post({:ok, %Post{}}, post_id, :publish), do: Posts.publish_post(post_id)
  defp maybe_publish_post(result, _post_id, _action), do: result

  defp maybe_publish_translation({:ok, _translation}, post_id, language, :publish), do: Posts.publish_post_translation(post_id, language)
  defp maybe_publish_translation(result, _post_id, _language, _action), do: result

  defp maybe_drop_old_language_draft(socket, _post_id, current_language, next_language) when current_language == next_language,
    do: socket

  defp maybe_drop_old_language_draft(socket, post_id, current_language, _next_language) do
    assign(socket, :post_editor_drafts, delete_nested_map(socket.assigns.post_editor_drafts, post_id, current_language))
  end

  defp toggled_sections(expanded_by_post, post_id, section) do
    expanded_by_post
    |> Map.get(post_id, %{metadata: false, excerpt: false})
    |> Map.put_new(:metadata, false)
    |> Map.put_new(:excerpt, false)
    |> Map.update!(section, &not &1)
  end

  defp put_nested_map(map, key, nested_key, value) do
    Map.update(map, key, %{nested_key => value}, &Map.put(&1, nested_key, value))
  end

  defp delete_nested_map(map, key, nested_key) do
    case Map.get(map, key) do
      nil -> map
      nested ->
        case Map.delete(nested, nested_key) do
          emptied when map_size(emptied) == 0 -> Map.delete(map, key)
          remaining -> Map.put(map, key, remaining)
        end
    end
  end
end
