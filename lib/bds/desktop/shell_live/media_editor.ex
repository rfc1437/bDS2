defmodule BDS.Desktop.ShellLive.MediaEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  import Ecto.Query

  alias BDS.Desktop.{FilePicker}
  alias BDS.Desktop.ShellLive.Notify
  alias BDS.{AI, I18n, Media}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation
  alias BDS.Posts.Post
  alias BDS.Repo
  use Gettext, backend: BDS.Gettext

  embed_templates("media_editor_html/*")

  @post_picker_limit 10

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> do_save()

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

  def update(%{action: :apply_ai_suggestions, fields: fields} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :fields]))
      |> do_apply_ai_suggestions(fields)

    {:ok, socket}
  end

  def update(%{action: :translate, language: language} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :language]))
      |> do_translate(language)

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
  def render(%{media_editor: nil} = assigns), do: ~H"<div></div>"

  def render(assigns) do
    media_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_media_editor", %{"media_editor" => params}, socket) do
    media = socket.assigns.media
    draft = normalize_params(params)
    dirty? = draft != persisted_form(media)
    was_dirty? = socket.assigns.dirty?

    socket =
      socket
      |> assign(:draft, draft)
      |> assign(:dirty?, dirty?)
      |> build_data()

    if dirty? != was_dirty? do
      Notify.dirty(:media, socket.assigns.media_id, dirty?)
    end

    {:noreply, socket}
  end

  def handle_event("save_media_editor", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("toggle_media_editor_quick_actions", _params, socket) do
    socket =
      socket
      |> assign(:quick_actions_open?, not socket.assigns.quick_actions_open?)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("replace_media_editor_file", _params, socket) do
    media = socket.assigns.media

    case FilePicker.choose_file(dgettext("ui", "Replace Media File")) do
      {:ok, source_path} ->
        case Media.replace_media_file(media.id, source_path) do
          {:ok, %MediaRecord{} = updated_media} ->
            socket =
              socket
              |> assign(:media, updated_media)
              |> assign(:draft, persisted_form(updated_media))
              |> assign(:dirty?, false)
              |> build_data()

            Notify.dirty(:media, media.id, false)

            Notify.tab_meta(:media, media.id, display_title(updated_media),
              updated_media.original_name || updated_media.mime_type || "")

            {:noreply, socket}

          {:ok, nil} ->
            {:noreply, build_data(socket)}

          {:error, reason} ->
            notify_output(socket, dgettext("ui", "Replace File"), inspect(reason), "error")
            {:noreply, build_data(socket)}
        end

      :cancel ->
        {:noreply, socket}

      {:error, %{message: message}} ->
        notify_output(socket, dgettext("ui", "Replace File"), message, "error")
        {:noreply, build_data(socket)}
    end
  end

  def handle_event("detect_media_editor_language", _params, socket) do
    if socket.assigns.offline_mode do
      notify_output(
        socket,
        dgettext("ui", "Detect Language"),
        dgettext("ui", "Automatic AI actions stay gated by airplane mode."),
        "info"
      )

      {:noreply, build_data(socket)}
    else
      media = socket.assigns.media
      draft = socket.assigns.draft

      text =
        Enum.join(
          [
            Map.get(draft, "title", ""),
            Map.get(draft, "alt", ""),
            Map.get(draft, "caption", "")
          ],
          "\n\n"
        )

      case AI.detect_language(text) do
        {:ok, %{language_code: language_code}}
        when is_binary(language_code) and language_code != "" ->
          normalized = normalize_language(language_code)

          case Media.update_media(media.id, %{language: normalized}) do
            {:ok, updated_media} ->
              updated_draft = Map.put(draft, "language", normalized)

              socket =
                socket
                |> assign(:media, updated_media)
                |> assign(:draft, updated_draft)
                |> assign(:dirty?, updated_draft != persisted_form(updated_media))
                |> build_data()

              {:noreply, socket}

            {:error, reason} ->
              notify_output(socket, dgettext("ui", "Detect Language"), inspect(reason), "error")
              {:noreply, build_data(socket)}
          end

        {:error, reason} ->
          notify_output(socket, dgettext("ui", "Detect Language"), inspect(reason), "error")
          {:noreply, build_data(socket)}

        _other ->
          notify_output(
            socket,
            dgettext("ui", "Detect Language"),
            dgettext("ui", "Language detection failed."),
            "error"
          )

          {:noreply, build_data(socket)}
      end
    end
  end

  def handle_event("toggle_media_post_picker", _params, socket) do
    socket =
      socket
      |> assign(:post_picker_open?, not socket.assigns.post_picker_open?)
      |> assign(:post_picker_query, "")
      |> build_data()

    {:noreply, socket}
  end

  def handle_event(
        "change_media_post_picker",
        %{"media_post_picker" => %{"query" => query}},
        socket
      ) do
    socket =
      socket
      |> assign(:post_picker_query, to_string(query || ""))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("link_media_to_post", %{"post-id" => post_id}, socket) do
    media = socket.assigns.media

    case Media.link_media_to_post(media.id, post_id) do
      {:ok, _linked} ->
        socket =
          socket
          |> assign(:post_picker_open?, false)
          |> assign(:post_picker_query, "")
          |> build_data()

        {:noreply, socket}

      {:error, reason} ->
        notify_output(socket, dgettext("ui", "Link to Post"), inspect(reason), "error")
        {:noreply, build_data(socket)}
    end
  end

  def handle_event("unlink_media_from_post", %{"post-id" => post_id}, socket) do
    media = socket.assigns.media

    case Media.unlink_media_from_post(media.id, post_id) do
      {:ok, _unlinked} ->
        {:noreply, build_data(socket)}

      {:error, reason} ->
        notify_output(socket, dgettext("ui", "Unlink from Post"), inspect(reason), "error")
        {:noreply, build_data(socket)}
    end
  end

  def handle_event("edit_media_translation", %{"language" => language}, socket) do
    media = socket.assigns.media
    translation = Repo.get_by(Translation, translation_for: media.id, language: language)

    form = %{
      "language" => language,
      "title" => (translation && translation.title) || "",
      "alt" => (translation && translation.alt) || "",
      "caption" => (translation && translation.caption) || ""
    }

    socket =
      socket
      |> assign(:editing_translation, form)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("change_media_translation", %{"media_translation" => params}, socket) do
    form = %{
      "language" => Map.get(params, "language", ""),
      "title" => Map.get(params, "title", ""),
      "alt" => Map.get(params, "alt", ""),
      "caption" => Map.get(params, "caption", "")
    }

    socket =
      socket
      |> assign(:editing_translation, form)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("save_media_translation", _params, socket) do
    media = socket.assigns.media

    case socket.assigns.editing_translation do
      %{"language" => language} = form when language not in [nil, ""] ->
        case Media.upsert_media_translation(media.id, language, %{
               title: blank_to_nil(Map.get(form, "title")),
               alt: blank_to_nil(Map.get(form, "alt")),
               caption: blank_to_nil(Map.get(form, "caption"))
             }) do
          {:ok, _translation} ->
            socket =
              socket
              |> assign(:editing_translation, nil)
              |> build_data()

            {:noreply, socket}

          {:error, reason} ->
            notify_output(socket, dgettext("ui", "Save Translation"), inspect(reason), "error")
            {:noreply, build_data(socket)}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("close_media_translation_editor", _params, socket) do
    socket =
      socket
      |> assign(:editing_translation, nil)
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("refresh_media_translation", %{"language" => language}, socket) do
    media = socket.assigns.media

    if socket.assigns.offline_mode do
      notify_output(
        socket,
        dgettext("ui", "Translate"),
        dgettext("ui", "Automatic AI actions stay gated by airplane mode."),
        "info"
      )

      {:noreply, build_data(socket)}
    else
      case AI.translate_media(media.id, normalize_language(language)) do
        {:ok, translation} ->
          case Media.upsert_media_translation(media.id, language, translation) do
            {:ok, _saved_translation} ->
              {:noreply, build_data(socket)}

            {:error, reason} ->
              notify_output(
                socket,
                dgettext("ui", "Refresh Translation"),
                inspect(reason),
                "error"
              )

              {:noreply, build_data(socket)}
          end

        {:error, reason} ->
          notify_output(socket, dgettext("ui", "Refresh Translation"), inspect(reason), "error")
          {:noreply, build_data(socket)}
      end
    end
  end

  def handle_event("delete_media_translation", %{"language" => language}, socket) do
    media = socket.assigns.media

    case Media.delete_media_translation(media.id, language) do
      {:ok, _deleted?} ->
        socket =
          socket
          |> assign(:editing_translation, nil)
          |> build_data()

        {:noreply, socket}

      {:error, reason} ->
        notify_output(socket, dgettext("ui", "Delete Translation"), inspect(reason), "error")
        {:noreply, build_data(socket)}
    end
  end

  defp ensure_state(socket) do
    media_id = socket.assigns.current_tab.id
    media = Media.get_media(media_id)

    defaults = %{
      media_id: media_id,
      media: media,
      draft: if(media, do: persisted_form(media), else: %{}),
      quick_actions_open?: false,
      post_picker_open?: false,
      post_picker_query: "",
      editing_translation: nil,
      dirty?: false,
      save_state: :idle
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
    case socket.assigns.media do
      nil ->
        assign(socket, :media_editor, nil)

      %MediaRecord{} = media ->
        linked_posts = Media.list_linked_posts(media.id)
        translations = Media.list_media_translations(media.id)
        draft = socket.assigns.draft
        picker_query = socket.assigns.post_picker_query

        {picker_results, picker_overflow_count} =
          post_picker_results(media, linked_posts, picker_query)

        data = %{
          id: media.id,
          display_title: display_title(media),
          original_name: media.original_name || media.filename || media.id,
          mime_type: media.mime_type || "application/octet-stream",
          file_size: format_file_size(media.size),
          dimensions: dimensions_label(media),
          is_image: image?(media),
          preview_url: preview_url(media),
          dirty?: socket.assigns.dirty?,
          save_state: socket.assigns.save_state,
          quick_actions_open?: socket.assigns.quick_actions_open?,
          post_picker_open?: socket.assigns.post_picker_open?,
          post_picker_query: picker_query,
          post_picker_results: picker_results,
          post_picker_overflow_count: picker_overflow_count,
          form: draft,
          languages: language_codes(),
          translations: Enum.map(translations, &translation_view/1),
          editing_translation: socket.assigns.editing_translation,
          linked_posts: linked_posts,
          can_detect_language?: detect_language_enabled?(draft),
          can_translate?: draft["language"] not in [nil, ""]
        }

        assign(socket, :media_editor, data)
    end
  end

  defp do_save(socket) do
    media = socket.assigns.media

    case media do
      nil ->
        socket

      %MediaRecord{} = media ->
        draft = socket.assigns.draft

        case persist(media, draft) do
          {:ok, updated_media} ->
            socket =
              socket
              |> assign(:media, updated_media)
              |> assign(:draft, persisted_form(updated_media))
              |> assign(:dirty?, false)
              |> assign(:save_state, :saved)
              |> build_data()

            Notify.dirty(:media, media.id, false)

            Notify.tab_meta(:media, media.id, display_title(updated_media),
              updated_media.original_name || updated_media.mime_type || "")

            notify_output(socket, dgettext("ui", "Media"), dgettext("ui", "Media saved"))
            socket

          {:error, reason} ->
            notify_output(socket, dgettext("ui", "Media"), inspect(reason), "error")
            |> build_data()
        end
    end
  end

  defp do_apply_ai_suggestions(socket, fields) do
    media = socket.assigns.media

    case media do
      nil ->
        socket

      %MediaRecord{} = _media ->
        updated_draft =
          Enum.reduce(fields, socket.assigns.draft, fn field, acc ->
            case field.key do
              "title" -> Map.put(acc, "title", field.suggested_value)
              "alt" -> Map.put(acc, "alt", field.suggested_value)
              "caption" -> Map.put(acc, "caption", field.suggested_value)
              _other -> acc
            end
          end)

        dirty? = updated_draft != persisted_form(media)

        socket =
          socket
          |> assign(:draft, updated_draft)
          |> assign(:dirty?, dirty?)
          |> assign(:save_state, :dirty)
          |> assign(:quick_actions_open?, false)
          |> build_data()

        Notify.dirty(:media, media.id, dirty?)
        socket
    end
  end

  defp do_translate(socket, language) do
    if socket.assigns.offline_mode do
      notify_output(
        socket,
        dgettext("ui", "Translate"),
        dgettext("ui", "Automatic AI actions stay gated by airplane mode."),
        "info"
      )

      build_data(socket)
    else
      media = socket.assigns.media
      normalized_language = normalize_language(language)
      source_language = normalize_language(media.language)

      case AI.translate_media(media.id, normalized_language, source_language: source_language) do
        {:ok, translation} ->
          case Media.upsert_media_translation(media.id, normalized_language, translation) do
            {:ok, _saved_translation} ->
              socket
              |> assign(:quick_actions_open?, false)
              |> assign(:editing_translation, nil)
              |> build_data()

            {:error, reason} ->
              notify_output(socket, dgettext("ui", "Translate"), inspect(reason), "error")
              |> build_data()
          end

        {:error, reason} ->
          notify_output(socket, dgettext("ui", "Translate"), inspect(reason), "error")
          |> build_data()
      end
    end
  end

  defp notify_output(socket, title, message, level \\ "info") do
    Notify.output(title, message, level)
    socket
  end

  @spec persist(term(), term()) :: term()
  def persist(%MediaRecord{} = media, draft) do
    Media.update_media(media.id, %{
      title: blank_to_nil(Map.get(draft, "title")),
      alt: blank_to_nil(Map.get(draft, "alt")),
      caption: blank_to_nil(Map.get(draft, "caption")),
      author: blank_to_nil(Map.get(draft, "author")),
      language: blank_to_nil(Map.get(draft, "language")),
      tags: csv_to_list(Map.get(draft, "tags"))
    })
  end

  defp translation_view(%Translation{} = translation) do
    %{
      language: translation.language,
      flag: I18n.flag(translation.language),
      title: translation.title,
      alt: translation.alt,
      caption: translation.caption
    }
  end

  defp post_picker_results(%MediaRecord{} = media, linked_posts, query) do
    linked_ids = MapSet.new(Enum.map(linked_posts, & &1.post_id))
    normalized_query = normalize_query(query)

    posts =
      Repo.all(
        from post in Post,
          where: post.project_id == ^media.project_id,
          order_by: [desc: post.updated_at, desc: post.created_at],
          select: %{
            post_id: post.id,
            title: fragment("COALESCE(?, ?, ?)", post.title, post.slug, post.id)
          }
      )
      |> Enum.reject(&MapSet.member?(linked_ids, &1.post_id))
      |> Enum.filter(fn post ->
        normalized_query == "" or String.contains?(String.downcase(post.title), normalized_query)
      end)

    {Enum.take(posts, @post_picker_limit), max(length(posts) - @post_picker_limit, 0)}
  end

  defp preview_url(%MediaRecord{} = media) do
    if image?(media),
      do: "/media-thumbnail/#{media.id}?size=large&t=#{media.updated_at}",
      else: nil
  end

  defp image?(%MediaRecord{} = media),
    do: String.starts_with?(to_string(media.mime_type || ""), "image/")

  defp display_title(%MediaRecord{} = media),
    do: blank_to_nil(media.title) || blank_to_nil(media.original_name) || media.id

  defp dimensions_label(%MediaRecord{width: width, height: height})
       when is_integer(width) and is_integer(height), do: "#{width} x #{height}"

  defp dimensions_label(_media), do: nil

  defp format_file_size(size) when is_integer(size) and size >= 1_048_576,
    do: :erlang.float_to_binary(size / 1_048_576, decimals: 1) <> " MB"

  defp format_file_size(size) when is_integer(size),
    do: :erlang.float_to_binary(size / 1024, decimals: 1) <> " KB"

  defp format_file_size(_size), do: "0.0 KB"

  defp detect_language_enabled?(form) do
    [Map.get(form, "title"), Map.get(form, "alt"), Map.get(form, "caption")]
    |> Enum.any?(&(blank_to_nil(&1) != nil))
  end

  defp language_codes do
    I18n.supported_languages()
    |> Enum.map(& &1.code)
  end

  defp normalize_params(params) do
    %{
      "title" => Map.get(params, "title", ""),
      "alt" => Map.get(params, "alt", ""),
      "caption" => Map.get(params, "caption", ""),
      "tags" => Map.get(params, "tags", ""),
      "author" => Map.get(params, "author", ""),
      "language" => Map.get(params, "language", "")
    }
  end

  defp persisted_form(%MediaRecord{} = media) do
    %{
      "title" => media.title || "",
      "alt" => media.alt || "",
      "caption" => media.caption || "",
      "tags" => Enum.join(media.tags, ", "),
      "author" => media.author || "",
      "language" => media.language || ""
    }
  end

  defp normalize_query(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp csv_to_list(value) do
    value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec media_editor_save_state_label(term()) :: term()
  def media_editor_save_state_label(:dirty), do: dgettext("ui", "Unsaved")
  def media_editor_save_state_label(:saved), do: dgettext("ui", "Saved")
  def media_editor_save_state_label(_state), do: dgettext("ui", "Idle")

  @spec language_label(term()) :: term()
  def language_label(code) do
    code
    |> to_string()
    |> String.upcase()
  end

  @spec normalize_language(term()) :: term()
  def normalize_language(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
