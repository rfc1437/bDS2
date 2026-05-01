defmodule BDS.Desktop.ShellLive.MediaEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.{FilePicker, ShellData}
  alias BDS.{AI, I18n, Media}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.UI.Workbench

  embed_templates("media_editor_html/*")

  @post_picker_limit 10

  @spec assign_socket(term()) :: term()
  def assign_socket(socket) do
    assign(socket, :media_editor, build(socket.assigns))
  end

  @spec update(term(), term(), term()) :: term()
  def update(socket, params, reload) do
    case socket.assigns.current_tab do
      %{type: :media, id: media_id} ->
        case Media.get_media(media_id) do
          nil ->
            socket

          %MediaRecord{} = media ->
            draft = normalize_params(params)
            socket |> reconcile_draft(media, draft) |> reload_with_assigned_workbench(reload)
        end

      _other ->
        socket
    end
  end

  @spec persist_socket(term(), term(), term(), term()) :: term()
  def persist_socket(socket, media_id, reload, append_output) do
    case Media.get_media(media_id) do
      nil ->
        socket

      %MediaRecord{} = media ->
        draft = current_draft(socket.assigns, media)

        case persist(media, draft) do
          {:ok, updated_media} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :media, media_id)

            socket
            |> assign(:workbench, workbench)
            |> assign(
              :media_editor_drafts,
              Map.delete(socket.assigns.media_editor_drafts, media_id)
            )
            |> assign(
              :media_editor_save_states,
              Map.put(socket.assigns.media_editor_save_states, media_id, :saved)
            )
            |> assign(
              :tab_meta,
              Map.put(socket.assigns.tab_meta, {:media, media_id}, tab_meta(updated_media))
            )
            |> reload.(workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Media"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec toggle_quick_actions(term(), term(), term()) :: term()
  def toggle_quick_actions(socket, media_id, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(
      :media_editor_quick_actions_open,
      Map.update(socket.assigns.media_editor_quick_actions_open, media_id, true, &(!&1))
    )
    |> reload.(workbench)
  end

  @spec replace_file(term(), term(), term(), term()) :: term()
  def replace_file(socket, media_id, reload, append_output) do
    case FilePicker.choose_file(translated("Replace Media File")) do
      {:ok, source_path} ->
        case Media.replace_media_file(media_id, source_path) do
          {:ok, %MediaRecord{} = updated_media} ->
            workbench = Workbench.clear_dirty(socket.assigns.workbench, :media, media_id)

            socket
            |> assign(:workbench, workbench)
            |> assign(
              :media_editor_drafts,
              Map.delete(socket.assigns.media_editor_drafts, media_id)
            )
            |> assign(
              :media_editor_save_states,
              Map.put(socket.assigns.media_editor_save_states, media_id, :saved)
            )
            |> assign(
              :tab_meta,
              Map.put(socket.assigns.tab_meta, {:media, media_id}, tab_meta(updated_media))
            )
            |> reload.(workbench)

          {:ok, nil} ->
            socket |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Replace File"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end

      :cancel ->
        socket

      {:error, %{message: message}} ->
        socket
        |> append_output.(translated("Replace File"), message, nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec detect_language(term(), term(), term(), term()) :: term()
  def detect_language(socket, media_id, reload, append_output) do
    if Map.get(socket.assigns, :offline_mode, true) do
      socket
      |> append_output.(
        translated("Detect Language"),
        translated("Automatic AI actions stay gated by airplane mode."),
        nil,
        "info"
      )
      |> reload.(socket.assigns.workbench)
    else
      case Media.get_media(media_id) do
        nil ->
          socket

        %MediaRecord{} = media ->
          draft = current_draft(socket.assigns, media)

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
                  updated_draft =
                    Map.put(current_draft(socket.assigns, media), "language", normalized)

                  socket
                  |> reconcile_draft(updated_media, updated_draft)
                  |> reload_with_assigned_workbench(reload)

                {:error, reason} ->
                  socket
                  |> append_output.(translated("Detect Language"), inspect(reason), nil, "error")
                  |> reload.(socket.assigns.workbench)
              end

            {:error, reason} ->
              socket
              |> append_output.(translated("Detect Language"), inspect(reason), nil, "error")
              |> reload.(socket.assigns.workbench)

            _other ->
              socket
              |> append_output.(
                translated("Detect Language"),
                translated("Language detection failed."),
                nil,
                "error"
              )
              |> reload.(socket.assigns.workbench)
          end
      end
    end
  end

  @spec translate(term(), term(), term(), term(), term()) :: term()
  def translate(socket, media_id, language, reload, append_output) do
    if Map.get(socket.assigns, :offline_mode, true) do
      socket
      |> append_output.(
        translated("Translate"),
        translated("Automatic AI actions stay gated by airplane mode."),
        nil,
        "info"
      )
      |> reload.(socket.assigns.workbench)
    else
      normalized_language = normalize_language(language)

      case AI.translate_media(media_id, normalized_language) do
        {:ok, translation} ->
          case Media.upsert_media_translation(media_id, normalized_language, translation) do
            {:ok, _saved_translation} ->
              socket
              |> assign(
                :media_editor_quick_actions_open,
                Map.put(socket.assigns.media_editor_quick_actions_open, media_id, false)
              )
              |> assign(
                :media_editor_translation_forms,
                Map.delete(socket.assigns.media_editor_translation_forms, media_id)
              )
              |> reload.(socket.assigns.workbench)

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

  @spec apply_ai_suggestions(term(), term(), term(), term(), term()) :: term()
  def apply_ai_suggestions(socket, media_id, fields, reload, append_output) do
    try do
      case Media.get_media(media_id) do
        nil ->
          socket

        %MediaRecord{} = media ->
          attrs =
            Enum.reduce(fields, current_draft(socket.assigns, media), fn field, acc ->
              case field.key do
                "title" -> Map.put(acc, "title", field.suggested_value)
                "alt" -> Map.put(acc, "alt", field.suggested_value)
                "caption" -> Map.put(acc, "caption", field.suggested_value)
                _other -> acc
              end
            end)

          socket
          |> assign(:shell_overlay, nil)
          |> reconcile_draft(media, attrs)
          |> reload_with_assigned_workbench(reload)
      end
    rescue
      error ->
        socket
        |> append_output.(translated("AI Suggestions"), inspect(error), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec delete_socket(term(), term(), term(), term()) :: term()
  def delete_socket(socket, media_id, reload, append_output) do
    case Media.delete_media(media_id) do
      {:ok, :deleted} ->
        workbench = Workbench.close_tab(socket.assigns.workbench, :media, media_id)

        socket
        |> assign(:workbench, workbench)
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:media, media_id}))
        |> assign(:media_editor_drafts, Map.delete(socket.assigns.media_editor_drafts, media_id))
        |> assign(
          :media_editor_quick_actions_open,
          Map.delete(socket.assigns.media_editor_quick_actions_open, media_id)
        )
        |> assign(
          :media_editor_post_pickers_open,
          Map.delete(socket.assigns.media_editor_post_pickers_open, media_id)
        )
        |> assign(
          :media_editor_post_picker_queries,
          Map.delete(socket.assigns.media_editor_post_picker_queries, media_id)
        )
        |> assign(
          :media_editor_save_states,
          Map.delete(socket.assigns.media_editor_save_states, media_id)
        )
        |> assign(
          :media_editor_translation_forms,
          Map.delete(socket.assigns.media_editor_translation_forms, media_id)
        )
        |> reload.(workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Delete Media"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec toggle_post_picker(term(), term(), term()) :: term()
  def toggle_post_picker(socket, media_id, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(
      :media_editor_post_pickers_open,
      Map.update(socket.assigns.media_editor_post_pickers_open, media_id, true, &(!&1))
    )
    |> reload.(workbench)
  end

  @spec set_post_picker_query(term(), term(), term(), term()) :: term()
  def set_post_picker_query(socket, media_id, query, reload) do
    workbench = socket.assigns.workbench

    socket
    |> assign(
      :media_editor_post_picker_queries,
      Map.put(socket.assigns.media_editor_post_picker_queries, media_id, to_string(query || ""))
    )
    |> reload.(workbench)
  end

  @spec link_post(term(), term(), term(), term(), term()) :: term()
  def link_post(socket, media_id, post_id, reload, append_output) do
    case Media.link_media_to_post(media_id, post_id) do
      {:ok, _linked} ->
        socket
        |> assign(
          :media_editor_post_pickers_open,
          Map.put(socket.assigns.media_editor_post_pickers_open, media_id, false)
        )
        |> assign(
          :media_editor_post_picker_queries,
          Map.put(socket.assigns.media_editor_post_picker_queries, media_id, "")
        )
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Link to Post"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec unlink_post(term(), term(), term(), term(), term()) :: term()
  def unlink_post(socket, media_id, post_id, reload, append_output) do
    case Media.unlink_media_from_post(media_id, post_id) do
      {:ok, _unlinked} ->
        socket |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Unlink from Post"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec edit_translation(term(), term(), term(), term()) :: term()
  def edit_translation(socket, media_id, language, reload) do
    workbench = socket.assigns.workbench

    translation = Repo.get_by(Translation, translation_for: media_id, language: language)

    form = %{
      "language" => language,
      "title" => (translation && translation.title) || "",
      "alt" => (translation && translation.alt) || "",
      "caption" => (translation && translation.caption) || ""
    }

    socket
    |> assign(
      :media_editor_translation_forms,
      Map.put(socket.assigns.media_editor_translation_forms, media_id, form)
    )
    |> reload.(workbench)
  end

  @spec update_translation(term(), term(), term(), term()) :: term()
  def update_translation(socket, media_id, params, reload) do
    workbench = socket.assigns.workbench

    form = %{
      "language" => Map.get(params, "language", ""),
      "title" => Map.get(params, "title", ""),
      "alt" => Map.get(params, "alt", ""),
      "caption" => Map.get(params, "caption", "")
    }

    socket
    |> assign(
      :media_editor_translation_forms,
      Map.put(socket.assigns.media_editor_translation_forms, media_id, form)
    )
    |> reload.(workbench)
  end

  @spec save_translation(term(), term(), term(), term()) :: term()
  def save_translation(socket, media_id, reload, append_output) do
    case Map.get(socket.assigns.media_editor_translation_forms, media_id) do
      %{"language" => language} = form when language not in [nil, ""] ->
        case Media.upsert_media_translation(media_id, language, %{
               title: blank_to_nil(Map.get(form, "title")),
               alt: blank_to_nil(Map.get(form, "alt")),
               caption: blank_to_nil(Map.get(form, "caption"))
             }) do
          {:ok, _translation} ->
            socket
            |> assign(
              :media_editor_translation_forms,
              Map.delete(socket.assigns.media_editor_translation_forms, media_id)
            )
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Save Translation"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end

      _other ->
        socket
    end
  end

  @spec refresh_translation(term(), term(), term(), term(), term()) :: term()
  def refresh_translation(socket, media_id, language, reload, append_output) do
    if Map.get(socket.assigns, :offline_mode, true) do
      socket
      |> append_output.(
        translated("Translate"),
        translated("Automatic AI actions stay gated by airplane mode."),
        nil,
        "info"
      )
      |> reload.(socket.assigns.workbench)
    else
      case AI.translate_media(media_id, normalize_language(language)) do
        {:ok, translation} ->
          case Media.upsert_media_translation(media_id, language, translation) do
            {:ok, _saved_translation} ->
              socket |> reload.(socket.assigns.workbench)

            {:error, reason} ->
              socket
              |> append_output.(translated("Refresh Translation"), inspect(reason), nil, "error")
              |> reload.(socket.assigns.workbench)
          end

        {:error, reason} ->
          socket
          |> append_output.(translated("Refresh Translation"), inspect(reason), nil, "error")
          |> reload.(socket.assigns.workbench)
      end
    end
  end

  @spec delete_translation(term(), term(), term(), term(), term()) :: term()
  def delete_translation(socket, media_id, language, reload, append_output) do
    case Media.delete_media_translation(media_id, language) do
      {:ok, _deleted?} ->
        socket
        |> assign(
          :media_editor_translation_forms,
          Map.delete(socket.assigns.media_editor_translation_forms, media_id)
        )
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Delete Translation"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec build(term()) :: term()
  def build(%{current_tab: %{type: :media, id: media_id}} = assigns) do
    case Media.get_media(media_id) do
      nil ->
        nil

      %MediaRecord{} = media ->
        linked_posts = Media.list_linked_posts(media.id)
        translations = Media.list_media_translations(media.id)
        form = current_draft(assigns, media)
        picker_query = Map.get(assigns.media_editor_post_picker_queries, media.id, "")

        {picker_results, picker_overflow_count} =
          post_picker_results(media, linked_posts, picker_query)

        %{
          id: media.id,
          display_title: display_title(media),
          original_name: media.original_name || media.filename || media.id,
          mime_type: media.mime_type || "application/octet-stream",
          file_size: format_file_size(media.size),
          dimensions: dimensions_label(media),
          is_image: image?(media),
          preview_url: preview_url(media),
          dirty?: Workbench.dirty?(assigns.workbench, :media, media.id),
          save_state: Map.get(assigns.media_editor_save_states, media.id, :idle),
          quick_actions_open?: Map.get(assigns.media_editor_quick_actions_open, media.id, false),
          post_picker_open?: Map.get(assigns.media_editor_post_pickers_open, media.id, false),
          post_picker_query: picker_query,
          post_picker_results: picker_results,
          post_picker_overflow_count: picker_overflow_count,
          form: form,
          languages: language_codes(),
          translations: Enum.map(translations, &translation_view/1),
          editing_translation: Map.get(assigns.media_editor_translation_forms, media.id),
          linked_posts: linked_posts,
          can_detect_language?: detect_language_enabled?(form),
          can_translate?: form["language"] not in [nil, ""]
        }
    end
  end

  def build(_assigns), do: nil

  @spec translated(term(), term()) :: term()
  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  @spec media_editor_save_state_label(term()) :: term()
  def media_editor_save_state_label(:dirty), do: translated("Unsaved")
  def media_editor_save_state_label(:saved), do: translated("Saved")
  def media_editor_save_state_label(_state), do: translated("Idle")

  @spec language_label(term()) :: term()
  def language_label(code) do
    code
    |> to_string()
    |> String.upcase()
  end

  @spec normalize_language(term()) :: term()
  def normalize_language(value), do: value |> to_string() |> String.trim() |> String.downcase()

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

  defp reconcile_draft(socket, %MediaRecord{} = media, draft) do
    persisted = persisted_form(media)
    dirty? = draft != persisted

    workbench =
      if dirty?,
        do: Workbench.mark_dirty(socket.assigns.workbench, :media, media.id),
        else: Workbench.clear_dirty(socket.assigns.workbench, :media, media.id)

    drafts =
      if dirty? do
        Map.put(socket.assigns.media_editor_drafts, media.id, draft)
      else
        Map.delete(socket.assigns.media_editor_drafts, media.id)
      end

    socket
    |> assign(:workbench, workbench)
    |> assign(:media_editor_drafts, drafts)
    |> assign(
      :media_editor_save_states,
      Map.put(
        socket.assigns.media_editor_save_states,
        media.id,
        if(dirty?, do: :dirty, else: :idle)
      )
    )
    |> assign(
      :tab_meta,
      Map.put(socket.assigns.tab_meta, {:media, media.id}, %{
        title: blank_to_nil(Map.get(draft, "title")) || display_title(media),
        subtitle: media.original_name || media.mime_type || ""
      })
    )
  end

  defp current_draft(assigns, %MediaRecord{} = media) do
    Map.get(assigns.media_editor_drafts, media.id, persisted_form(media))
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

  defp tab_meta(%MediaRecord{} = media) do
    %{title: display_title(media), subtitle: media.original_name || media.mime_type || ""}
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

  defp reload_with_assigned_workbench(socket, reload),
    do: reload.(socket, socket.assigns.workbench)
end
