defmodule BDS.Desktop.ShellLive.PostEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.{AI, Posts, Preview, Repo}
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.PostEditor.{DraftManagement, ListValues, Persistence, PostMetadata}
  alias BDS.Posts.Post
  alias BDS.Tags
  alias BDS.UI.Workbench

  import DraftManagement,
    only: [
      current_draft: 4,
      delete_nested_map: 3,
      editing_canonical_language?: 3,
      maybe_update_draft: 7,
      normalize_language: 2,
      normalize_mode: 1,
      normalize_params: 3,
      persisted_form: 3,
      put_draft_field: 6,
      put_nested_map: 4,
      put_query_state: 4,
      query_value: 3,
      record_status: 1,
      record_title: 2,
      reload_with_assigned_workbench: 2,
      save_state_for_action: 1,
      toggled_sections: 3
    ]

  import ListValues,
    only: [
      category_suggestions: 3,
      category_values: 1,
      csv_to_list: 1,
      ensure_list_value: 3,
      field_key: 1,
      normalize_list_entry: 1,
      query_addable?: 4,
      tag_chips: 2,
      tag_suggestions: 3,
      tag_values: 1
    ]

  import Persistence,
    only: [
      discard: 3,
      discard_label: 1,
      discard_title: 1,
      has_published_version?: 1,
      persist: 5
    ]

  import PostMetadata,
    only: [
      blank?: 1,
      blank_to_nil: 1,
      canonical_language: 2,
      display_title: 3,
      footer: 4,
      gallery_count: 1,
      languages: 1,
      linked_media: 1,
      post_links: 1,
      preview_url: 4,
      project_metadata: 1,
      template_options: 1,
      translation_flags: 4,
      translations: 1
    ]

  defdelegate tag_chip_style(color), to: ListValues

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
    normalized_mode = normalize_mode(mode)

    if normalized_mode == :preview do
      case Repo.get(Post, post_id) do
        %Post{} = post ->
          _ = Preview.ensure_preview(post.project_id)

        _other ->
          :ok
      end
    end

    socket
    |> assign(:post_editor_modes, Map.put(socket.assigns.post_editor_modes, post_id, normalized_mode))
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
        persisted = DraftManagement.persisted_form(post, metadata, active_language, translations)

        form =
          assigns.post_editor_drafts
          |> Map.get(post.id, %{})
          |> Map.get(active_language, persisted)

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

  def post_status_label(status), do: ShellData.dashboard_status_label(status)

  def post_editor_save_state_label(:dirty), do: translated("Unsaved")
  def post_editor_save_state_label(:saved), do: translated("Saved")
  def post_editor_save_state_label(:published), do: translated("Published")
  def post_editor_save_state_label(:discarded), do: translated("Reverted")
  def post_editor_save_state_label(_state), do: translated("Idle")

  def post_editor_mode_label(:markdown), do: translated("Markdown")
  def post_editor_mode_label(:preview), do: translated("Preview")

  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  defp assigned_project_metadata(assigns), do: Map.get(assigns, :project_metadata, %{})
end
