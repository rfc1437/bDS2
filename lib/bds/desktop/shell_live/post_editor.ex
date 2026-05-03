defmodule BDS.Desktop.ShellLive.PostEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  alias BDS.{AI, Posts, Preview}
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.PostEditor.{DraftManagement, ListValues, Persistence, PostMetadata}
  alias BDS.Desktop.UILocale
  alias BDS.Posts.Post
  alias BDS.Tags

  import DraftManagement,
    only: [
      current_draft: 4,
      editing_canonical_language?: 3,
      normalize_language: 2,
      normalize_mode: 1,
      normalize_params: 3,
      persisted_form: 3,
      persisted_form: 4,
      record_status: 1,
      record_title: 2,
      save_state_for_action: 1
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

  embed_templates("post_editor_html/*")

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> do_save()

    {:ok, socket}
  end

  def update(%{action: :publish} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> do_publish()

    {:ok, socket}
  end

  def update(%{action: :close_quick_actions} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:quick_actions_open?, false)
      |> build_data()

    {:ok, socket}
  end

  def update(%{action: :insert_content, content: content} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :content]))
      |> Phoenix.LiveView.push_event("post-editor-insert-content", %{
        id: socket.assigns.post_id,
        content: content
      })
      |> assign(:shell_overlay, nil)

    {:ok, socket}
  end

  def update(%{action: :translate, language: language} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :language]))
      |> do_translate(language)

    {:ok, socket}
  end

  def update(%{action: :apply_ai_suggestions, fields: fields} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :fields]))
      |> do_apply_ai_suggestions(fields)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> ensure_state()
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(%{post_editor: nil} = assigns), do: ~H"<div></div>"

  def render(assigns) do
    post_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_post_editor", %{"post_editor" => params}, socket) do
    post_id = socket.assigns.post_id
    current_language = socket.assigns.active_language
    metadata = socket.assigns.project_metadata
    post = socket.assigns.post

    requested_language = normalize_language(Map.get(params, "language"), current_language)

    next_language =
      if current_language == socket.assigns.canonical_language do
        requested_language
      else
        current_language
      end

    draft = normalize_params(params, current_language, next_language)
    current = component_current_draft(socket, post, metadata, next_language)
    dirty? = draft != current
    was_dirty? = socket.assigns.dirty?

    socket =
      socket
      |> assign(:tag_query, Map.get(params, "tag_query", ""))
      |> assign(:category_query, Map.get(params, "category_query", ""))
      |> maybe_update_component_draft(next_language, draft)
      |> assign(:dirty?, dirty?)
      |> build_data()

    if dirty? != was_dirty? do
      notify_parent({:post_editor_dirty, post_id, dirty?})
    end

    {:noreply, socket}
  end

  def handle_event("save_post_editor", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("publish_post_editor", _params, socket) do
    {:noreply, do_publish(socket)}
  end

  def handle_event("discard_post_editor", _params, socket) do
    {:noreply, do_discard(socket)}
  end

  def handle_event("delete_post_editor", _params, socket) do
    {:noreply, do_delete(socket)}
  end

  def handle_event("set_post_editor_mode", %{"mode" => mode}, socket) do
    normalized_mode = normalize_mode(mode)

    if normalized_mode == :preview do
      case socket.assigns.post do
        %Post{} = post -> _ = Preview.ensure_preview(post.project_id)
        _other -> :ok
      end
    end

    socket =
      socket
      |> assign(:mode, normalized_mode)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("toggle_post_metadata", _params, socket) do
    socket =
      socket
      |> assign(:expanded, Map.update(socket.assigns.expanded, :metadata, false, &(!&1)))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("toggle_post_excerpt", _params, socket) do
    socket =
      socket
      |> assign(:expanded, Map.update(socket.assigns.expanded, :excerpt, false, &(!&1)))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("select_post_editor_language", %{"language" => language}, socket) do
    socket =
      socket
      |> assign(:active_language, normalize_language(language, language))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("toggle_post_editor_quick_actions", _params, socket) do
    socket =
      socket
      |> assign(:quick_actions_open?, not socket.assigns.quick_actions_open?)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("detect_post_editor_language", _params, socket) do
    {:noreply, do_detect_language(socket)}
  end

  def handle_event("add_post_editor_tag", %{"tag" => tag}, socket) do
    {:noreply, do_add_list_value(socket, :tags, tag)}
  end

  def handle_event("remove_post_editor_tag", %{"tag" => tag}, socket) do
    {:noreply, do_remove_list_value(socket, :tags, tag)}
  end

  def handle_event("add_post_editor_category", %{"category" => category}, socket) do
    {:noreply, do_add_list_value(socket, :categories, category)}
  end

  def handle_event("remove_post_editor_category", %{"category" => category}, socket) do
    {:noreply, do_remove_list_value(socket, :categories, category)}
  end

  def handle_event("insert_content", %{"content" => content}, socket) do
    socket =
      socket
      |> Phoenix.LiveView.push_event("post-editor-insert-content", %{
        id: socket.assigns.post_id,
        content: content
      })
      |> assign(:shell_overlay, nil)

    {:noreply, socket}
  end

  def handle_event("close_quick_actions", _params, socket) do
    socket =
      socket
      |> assign(:quick_actions_open?, false)
      |> build_data()

    {:noreply, socket}
  end

  defp component_current_draft(socket, post, metadata, active_language) do
    persisted = persisted_form(post, metadata, active_language)
    Map.get(socket.assigns.drafts, active_language, persisted)
  end

  defp ensure_state(socket) do
    post_id = socket.assigns.current_tab.id
    post = Posts.get_post(post_id)
    metadata = project_metadata(post && post.project_id)
    canonical = if post, do: canonical_language(post, metadata), else: "en"

    defaults = %{
      post_id: post_id,
      post: post,
      project_metadata: metadata,
      canonical_language: canonical,
      active_language: canonical,
      drafts: %{},
      tag_query: "",
      category_query: "",
      quick_actions_open?: false,
      mode: :markdown,
      expanded: %{metadata: post && blank?(post.title), excerpt: post && not blank?(post.excerpt)},
      save_state: :idle,
      dirty?: false
    }

    Enum.reduce(defaults, socket, fn {key, default}, acc ->
      if is_nil(Map.get(acc.assigns, key)) do
        assign(acc, key, default)
      else
        acc
      end
    end)
  end

  defp build_data(socket) do
    case socket.assigns.post do
      nil ->
        assign(socket, :post_editor, nil)

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        canonical_language = socket.assigns.canonical_language
        active_language = socket.assigns.active_language
        translations = translations(post.id)
        persisted = persisted_form(post, metadata, active_language, translations)

        form =
          socket.assigns.drafts
          |> Map.get(active_language, persisted)

        expanded = socket.assigns.expanded
        current_translation = Map.get(translations, active_language)

        data = %{
          id: post.id,
          display_title: display_title(form["title"], post.slug, post.id),
          subtitle: nil,
          slug: post.slug || post.id,
          status: post.status,
          dirty?: socket.assigns.dirty?,
          save_state: socket.assigns.save_state,
          quick_actions_open?: socket.assigns.quick_actions_open?,
          metadata_expanded: Map.get(expanded, :metadata, false),
          excerpt_expanded: Map.get(expanded, :excerpt, false),
          mode: socket.assigns.mode,
          editing_canonical?:
            editing_canonical_language?(translations, active_language, canonical_language),
          can_publish?: post.status == :draft,
          can_delete?: post.status == :published,
          has_published_version?: has_published_version?(post),
          discard_label: discard_label(post),
          discard_title: discard_title(post),
          detect_language_enabled?:
            not blank?(Map.get(form, "title")) or not blank?(Map.get(form, "content")),
          can_translate?: Enum.any?(languages(metadata), &(&1 != canonical_language)),
          languages: languages(metadata),
          form: form,
          template_options: template_options(post.project_id),
          show_template_selector?: template_options(post.project_id) != [],
          tag_options: Tags.list_tags(post.project_id),
          tag_values: tag_values(form),
          tag_chips: tag_chips(form, Tags.list_tags(post.project_id)),
          tag_query: socket.assigns.tag_query,
          tag_query_addable?:
            query_addable?(
              socket.assigns.tag_query,
              tag_values(form),
              Tags.list_tags(post.project_id),
              fn option -> option.name end
            ),
          category_values: category_values(form),
          category_query: socket.assigns.category_query,
          category_options: metadata.categories || [],
          category_query_addable?:
            query_addable?(
              socket.assigns.category_query,
              category_values(form),
              metadata.categories || [],
              & &1
            ),
          tag_suggestions:
            tag_suggestions(
              form,
              Tags.list_tags(post.project_id),
              socket.assigns.tag_query
            ),
          category_suggestions:
            category_suggestions(
              form,
              metadata.categories || [],
              socket.assigns.category_query
            ),
          gallery_count: gallery_count(form),
          preview_url:
            preview_url(
              post,
              active_language,
              canonical_language,
              socket.assigns.mode
            ),
          translation_flags:
            translation_flags(post, canonical_language, active_language, translations),
          linked_media: linked_media(post.id),
          post_links: post_links(post.id),
          footer: footer(post, current_translation, active_language, canonical_language)
        }

        assign(socket, :post_editor, data)
    end
  end

  defp do_save(socket) do
    post = socket.assigns.post

    case post do
      nil ->
        socket

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        active_language = socket.assigns.active_language
        draft = component_current_draft(socket, post, metadata, active_language)

        case persist(post, draft, active_language, metadata, :save) do
          {:ok, record} ->
            refreshed_post = Posts.get_post!(post.id)
            _refreshed_form = persisted_form(refreshed_post, metadata, active_language)

            socket =
              socket
              |> assign(:post, refreshed_post)
              |> assign(:drafts, Map.delete(socket.assigns.drafts, active_language))
              |> assign(:save_state, save_state_for_action(:save))
              |> assign(:dirty?, false)
              |> build_data()

            notify_parent(
              {:post_editor_tab_meta, post.id, record_title(record, refreshed_post),
               Atom.to_string(record_status(record))}
            )

            notify_parent({:post_editor_dirty, post.id, false})
            notify_output(socket, translated("Post"), translated("Post saved"))
            socket

          {:error, reason} ->
            notify_output(socket, translated("Post"), inspect(reason), "error")
            |> build_data()
        end
    end
  end

  defp do_publish(socket) do
    post = socket.assigns.post

    case post do
      nil ->
        socket

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        active_language = socket.assigns.active_language
        draft = component_current_draft(socket, post, metadata, active_language)

        case persist(post, draft, active_language, metadata, :publish) do
          {:ok, record} ->
            refreshed_post = Posts.get_post!(post.id)
            _refreshed_form = persisted_form(refreshed_post, metadata, active_language)

            socket =
              socket
              |> assign(:post, refreshed_post)
              |> assign(:drafts, Map.delete(socket.assigns.drafts, active_language))
              |> assign(:save_state, save_state_for_action(:publish))
              |> assign(:dirty?, false)
              |> build_data()

            notify_parent(
              {:post_editor_tab_meta, post.id, record_title(record, refreshed_post),
               Atom.to_string(record_status(record))}
            )

            notify_parent({:post_editor_dirty, post.id, false})
            notify_output(socket, translated("Post"), translated("Post published"))
            socket

          {:error, reason} ->
            notify_output(socket, translated("Post"), inspect(reason), "error")
            |> build_data()
        end
    end
  end

  defp do_discard(socket) do
    post = socket.assigns.post

    case post do
      nil ->
        socket

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        active_language = socket.assigns.active_language

        case discard(post, active_language, metadata) do
          {:ok, restored_post} ->
            socket =
              socket
              |> assign(:post, restored_post)
              |> assign(:drafts, Map.delete(socket.assigns.drafts, active_language))
              |> assign(:save_state, :discarded)
              |> assign(:dirty?, false)
              |> build_data()

            notify_parent(
              {:post_editor_tab_meta, post.id,
               restored_post.title || restored_post.slug || restored_post.id,
               Atom.to_string(restored_post.status || :draft)}
            )

            notify_parent({:post_editor_dirty, post.id, false})
            socket

          {:error, reason} ->
            notify_output(socket, translated("Post"), inspect(reason), "error")
            |> build_data()
        end
    end
  end

  defp do_delete(socket) do
    post_id = socket.assigns.post_id

    case Posts.delete_post(post_id) do
      {:ok, :deleted} ->
        notify_parent({:close_tab, :post, post_id})
        socket

      {:error, reason} ->
        notify_output(socket, translated("Post"), inspect(reason), "error")
        |> build_data()
    end
  end

  defp do_detect_language(socket) do
    if Map.get(socket.assigns, :offline_mode, true) do
      notify_output(
        socket,
        translated("Detect Language"),
        translated("Automatic AI actions stay gated by airplane mode."),
        "info"
      )
      |> build_data()
    else
      post = socket.assigns.post

      case post do
        nil ->
          socket

        %Post{} = post ->
          metadata = socket.assigns.project_metadata
          active_language = socket.assigns.active_language
          draft = component_current_draft(socket, post, metadata, active_language)
          text = Enum.join([Map.get(draft, "title", ""), Map.get(draft, "content", "")], "\n\n")

          case AI.detect_language(text) do
            {:ok, %{language_code: language_code}}
            when is_binary(language_code) and language_code != "" ->
              socket
              |> put_component_draft_field("language", normalize_language(language_code, socket.assigns.canonical_language))
              |> build_data()

            {:error, reason} ->
              notify_output(socket, translated("Detect Language"), inspect(reason), "error")
              |> build_data()

            _other ->
              notify_output(
                socket,
                translated("Detect Language"),
                translated("Language detection failed."),
                "error"
              )
              |> build_data()
          end
      end
    end
  end

  defp do_translate(socket, language) do
    if Map.get(socket.assigns, :offline_mode, true) do
      notify_output(
        socket,
        translated("Translate"),
        translated("Automatic AI actions stay gated by airplane mode."),
        "info"
      )
      |> build_data()
    else
      post_id = socket.assigns.post_id
      normalized_language = normalize_language(language, "")

      case AI.translate_post(post_id, normalized_language) do
        {:ok, translation} ->
          with {:ok, _saved_translation} <-
                 Posts.upsert_post_translation(post_id, normalized_language, %{
                   title: translation.title,
                   excerpt: translation.excerpt,
                   content: translation.content
                 }) do
            socket =
              socket
              |> assign(:active_language, normalized_language)
              |> assign(:drafts, Map.delete(socket.assigns.drafts, normalized_language))
              |> assign(:quick_actions_open?, false)
              |> build_data()

            notify_parent({:post_editor_dirty, post_id, false})
            socket
          else
            {:error, reason} ->
              notify_output(socket, translated("Translate"), inspect(reason), "error")
              |> build_data()
          end

        {:error, reason} ->
          notify_output(socket, translated("Translate"), inspect(reason), "error")
          |> build_data()
      end
    end
  end

  defp do_apply_ai_suggestions(socket, fields) do
    post_id = socket.assigns.post_id

    case Posts.get_post(post_id) do
      nil ->
        socket

      %Post{} = _post ->
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
          assign(socket, :shell_overlay, nil)
        else
          case Posts.update_post(post_id, attrs) do
            {:ok, updated_post} ->
              metadata = project_metadata(updated_post.project_id)
              active_language = socket.assigns.active_language
              refreshed_form = persisted_form(updated_post, metadata, active_language)

              socket =
                socket
                |> assign(:post, updated_post)
                |> assign(:project_metadata, metadata)
                |> assign(:drafts, Map.put(socket.assigns.drafts, active_language, refreshed_form))
                |> assign(:save_state, :dirty)
                |> assign(:dirty?, true)
                |> assign(:shell_overlay, nil)
                |> build_data()

              notify_parent({:post_editor_dirty, post_id, true})
              socket

            {:error, reason} ->
              notify_output(socket, translated("AI Suggestions"), inspect(reason), "error")
              |> build_data()
          end
        end
    end
  end

  defp do_add_list_value(socket, kind, value) do
    post = socket.assigns.post

    case post do
      nil ->
        socket

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        active_language = socket.assigns.active_language
        draft = component_current_draft(socket, post, metadata, active_language)
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

          socket =
            socket
            |> assign_query(kind, "")
            |> put_component_draft_field(field_key(kind), updated)
            |> build_data()

          notify_parent({:post_editor_dirty, socket.assigns.post_id, true})
          assign(socket, :dirty?, true)
        end
    end
  end

  defp do_remove_list_value(socket, kind, value) do
    post = socket.assigns.post

    case post do
      nil ->
        socket

      %Post{} = post ->
        metadata = socket.assigns.project_metadata
        active_language = socket.assigns.active_language
        draft = component_current_draft(socket, post, metadata, active_language)

        updated =
          draft
          |> Map.get(field_key(kind), "")
          |> csv_to_list()
          |> Enum.reject(&(&1 == value))
          |> Enum.join(", ")

        socket =
          socket
          |> put_component_draft_field(field_key(kind), updated)
          |> build_data()

        notify_parent({:post_editor_dirty, socket.assigns.post_id, true})
        assign(socket, :dirty?, true)
    end
  end

  defp maybe_update_component_draft(socket, next_language, draft) do
    current_language = socket.assigns.active_language

    cond do
      current_language == next_language ->
        assign(socket, :drafts, Map.put(socket.assigns.drafts, next_language, draft))

      Map.has_key?(socket.assigns.drafts, current_language) ->
        socket
        |> assign(:active_language, next_language)
        |> assign(:drafts, Map.put(socket.assigns.drafts, next_language, draft))

      true ->
        socket
        |> assign(:active_language, next_language)
        |> assign(:drafts, Map.put(%{}, next_language, draft))
    end
  end

  defp put_component_draft_field(socket, field, value) do
    active_language = socket.assigns.active_language
    post = socket.assigns.post
    metadata = socket.assigns.project_metadata
    draft = current_draft(socket.assigns, post, metadata, active_language)
    updated = Map.put(draft, field, value)
    assign(socket, :drafts, Map.put(socket.assigns.drafts, active_language, updated))
  end

  defp assign_query(socket, :tags, value), do: assign(socket, :tag_query, value)
  defp assign_query(socket, :categories, value), do: assign(socket, :category_query, value)

  defp notify_parent(message) do
    send(self(), message)
  end

  defp notify_output(socket, title, message, level \\ "info") do
    send(self(), {:post_editor_output, title, message, level})
    socket
  end

  @spec post_status_label(term()) :: term()
  def post_status_label(status), do: ShellData.dashboard_status_label(status)

  @spec post_editor_save_state_label(term()) :: term()
  def post_editor_save_state_label(:dirty), do: translated("Unsaved")
  def post_editor_save_state_label(:saved), do: translated("Saved")
  def post_editor_save_state_label(:published), do: translated("Published")
  def post_editor_save_state_label(:discarded), do: translated("Reverted")
  def post_editor_save_state_label(_state), do: translated("Idle")

  @spec post_editor_mode_label(term()) :: term()
  def post_editor_mode_label(:markdown), do: translated("Markdown")
  def post_editor_mode_label(:preview), do: translated("Preview")

  @spec translated(term(), term()) :: term()
  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, UILocale.current())
end
