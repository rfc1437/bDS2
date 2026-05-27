defmodule BDS.Desktop.Overlay do
  @moduledoc false

  def open(:post, :ai_suggestions, context) do
    %{
      kind: :ai_suggestions,
      title: Map.get(context, :ai_title, "AI Suggestions"),
      fields: normalize_ai_fields(Map.get(context, :ai_fields, []))
    }
  end

  def open(:media, :ai_suggestions, context), do: open(:post, :ai_suggestions, context)

  def open(:post, :insert_link, context) do
    posts = related_posts(Map.get(context, :posts, []), current_id(context))

    %{
      kind: :insert_link,
      title: Map.get(context, :insert_link_title, "Insert Link"),
      active_tab: :internal,
      search_query: "",
      external_url: "",
      external_text: current_title(context),
      results: [],
      related_posts: Enum.map(Enum.take(posts, 5), &to_insert_link_result/1),
      all_posts: posts
    }
  end

  def open(:post, :insert_media, context) do
    media = Map.get(context, :media, [])

    %{
      kind: :insert_media,
      title: Map.get(context, :insert_media_title, "Insert Media"),
      search_query: "",
      results: Enum.map(media, &to_insert_media_result/1),
      all_media: media
    }
  end

  def open(:post, :language_picker, context) do
    language_picker(context, Map.get(context, :current_post_language, "en"))
  end

  def open(:media, :language_picker, context) do
    language_picker(context, Map.get(context, :current_media_language, "en"))
  end

  def open(:media, :confirm_delete, context) do
    %{
      title: title,
      entity_name: entity_name,
      entity_type: entity_type,
      reference_list: reference_list
    } = context.delete_details

    %{
      kind: :confirm_delete,
      title: title,
      entity_name: entity_name,
      entity_type: entity_type,
      reference_count: length(reference_list),
      reference_list: reference_list
    }
  end

  def open(:tags, :confirm_delete, context), do: open(:media, :confirm_delete, context)

  def open(:tags, :confirm_merge, context) do
    %{title: title, message: message} = context.merge_details

    %{
      kind: :confirm_dialog,
      title: title,
      message: message
    }
  end

  def open(:post, :gallery, context) do
    images =
      context
      |> gallery_images()
      |> Enum.map(&to_gallery_image/1)

    %{
      kind: :gallery,
      title: Map.get(context, :gallery_title, current_title(context)),
      post_id: current_id(context),
      images: images,
      lightbox: nil
    }
  end

  def open(_route, _action, _context), do: nil

  def set_search_query(%{kind: :insert_link} = overlay, query) do
    normalized = normalize_query(query)

    results =
      if String.length(normalized) < 2 do
        []
      else
        overlay
        |> Map.get(:all_posts, [])
        |> Enum.filter(&search_matches?(&1.title, normalized))
        |> Enum.map(&to_insert_link_result/1)
      end

    %{overlay | search_query: normalized, results: results}
  end

  def set_search_query(%{kind: :insert_media} = overlay, query) do
    normalized = normalize_query(query)

    results =
      overlay
      |> Map.get(:all_media, [])
      |> Enum.filter(fn media ->
        normalized == "" or
          search_matches?(media.title, normalized) or
          search_matches?(media.original_name, normalized)
      end)
      |> Enum.map(&to_insert_media_result/1)

    %{overlay | search_query: normalized, results: results}
  end

  def set_search_query(overlay, _query), do: overlay

  def set_active_tab(%{kind: :insert_link} = overlay, tab) when tab in [:internal, :external] do
    %{overlay | active_tab: tab}
  end

  def set_active_tab(overlay, _tab), do: overlay

  def update_form_value(%{kind: :insert_link} = overlay, :external_url, value) do
    %{overlay | external_url: normalize_query(value)}
  end

  def update_form_value(%{kind: :insert_link} = overlay, :external_text, value) do
    %{overlay | external_text: to_string(value || "")}
  end

  def update_form_value(overlay, _key, _value), do: overlay

  def toggle_ai_field(%{kind: :ai_suggestions} = overlay, key) do
    fields =
      Enum.map(overlay.fields, fn field ->
        if field.key == key and not field.locked do
          %{field | accepted: not field.accepted}
        else
          field
        end
      end)

    %{overlay | fields: fields}
  end

  def toggle_ai_field(overlay, _key), do: overlay

  def select_gallery_image(%{kind: :gallery} = overlay, media_id) do
    case Enum.find_index(overlay.images, &(&1.media_id == media_id)) do
      nil -> overlay
      index -> %{overlay | lightbox: lightbox_from_index(overlay.images, index)}
    end
  end

  def select_gallery_image(overlay, _media_id), do: overlay

  def close_lightbox(%{kind: :gallery} = overlay), do: %{overlay | lightbox: nil}
  def close_lightbox(overlay), do: overlay

  def lightbox_next(%{kind: :gallery, lightbox: lightbox, images: images} = overlay)
      when is_map(lightbox) and images != [] do
    next_index = rem(lightbox.current_index + 1, length(images))
    %{overlay | lightbox: lightbox_from_index(images, next_index)}
  end

  def lightbox_next(overlay), do: overlay

  def lightbox_previous(%{kind: :gallery, lightbox: lightbox, images: images} = overlay)
      when is_map(lightbox) and images != [] do
    next_index = rem(lightbox.current_index - 1 + length(images), length(images))
    %{overlay | lightbox: lightbox_from_index(images, next_index)}
  end

  def lightbox_previous(overlay), do: overlay

  def selected_ai_fields(%{kind: :ai_suggestions, fields: fields}) do
    Enum.filter(fields, & &1.accepted)
  end

  def selected_ai_fields(_overlay), do: []

  def insert_link_result(%{kind: :insert_link} = overlay, post_id) do
    Enum.find(overlay.results ++ overlay.related_posts, &(&1.post_id == post_id))
  end

  def insert_link_result(_overlay, _post_id), do: nil

  def insert_media_result(%{kind: :insert_media} = overlay, media_id) do
    Enum.find(overlay.results, &(&1.media_id == media_id))
  end

  def insert_media_result(_overlay, _media_id), do: nil

  defp language_picker(context, source_language) do
    existing_translations = Map.get(context, :existing_translations, %{})
    language_names = Map.get(context, :language_names, %{})
    language_flags = Map.get(context, :language_flags, %{})

    targets =
      context
      |> Map.get(:blog_languages, [])
      |> Enum.uniq()
      |> Enum.reject(&(&1 == source_language))
      |> Enum.map(fn code ->
        existing_status = Map.get(existing_translations, code)

        %{
          code: code,
          name: Map.get(language_names, code, String.upcase(code)),
          flag_emoji: Map.get(language_flags, code, code),
          has_existing_translation: not is_nil(existing_status),
          existing_status: existing_status
        }
      end)

    %{
      kind: :language_picker,
      title: Map.get(context, :language_picker_title, "Translate"),
      source_language: source_language,
      available_targets: targets
    }
  end

  def set_ai_suggestions(%{kind: :ai_suggestions} = overlay, suggestions) do
    fields =
      Enum.map(overlay.fields, fn field ->
        case Map.get(suggestions, field.key) do
          nil ->
            field

          value when is_binary(value) and value != "" ->
            %{field | suggested_value: value, loading: false}

          _other ->
            field
        end
      end)

    %{overlay | fields: fields}
  end

  def set_ai_suggestions(overlay, _suggestions), do: overlay

  def set_ai_suggestions_error(%{kind: :ai_suggestions} = overlay, error_message) do
    Map.put(overlay, :error, error_message)
  end

  def set_ai_suggestions_error(overlay, _error_message), do: overlay

  defp normalize_ai_fields(fields) do
    Enum.map(fields, fn %{key: key, label: label, current_value: current,
                          suggested_value: suggested, locked: locked} = field ->
      %{
        key: to_string(key),
        label: label,
        current_value: current,
        suggested_value: suggested,
        accepted: not locked,
        locked: locked,
        loading: Map.get(field, :loading, false)
      }
    end)
  end

  defp current_id(context), do: get_in(context, [:current_tab, :id])
  defp current_title(context), do: get_in(context, [:current_tab, :title]) || ""

  defp related_posts(posts, current_post_id) do
    Enum.reject(posts, &(&1.id == current_post_id))
  end

  defp gallery_images(context) do
    images = Enum.filter(Map.get(context, :media, []), & &1.is_image)
    post_media_ids = Map.get(context, :post_media_ids, [])

    case Enum.filter(images, &(&1.id in post_media_ids)) do
      [] -> images
      linked -> linked
    end
  end

  defp to_insert_link_result(post) do
    %{
      post_id: post.id,
      title: post.title,
      status: post.status,
      canonical_url: post.canonical_url,
      similarity_score: nil
    }
  end

  defp to_insert_media_result(media) do
    %{
      media_id: media.id,
      title: media.title,
      original_name: media.original_name,
      is_image: media.is_image,
      thumbnail_url: media.thumbnail_url
    }
  end

  defp to_gallery_image(media) do
    %{
      media_id: media.id,
      thumbnail_url: media.thumbnail_url,
      image_url: media.image_url,
      alt_text: media.alt_text,
      title: media.title
    }
  end

  defp lightbox_from_index(images, index) do
    image = Enum.at(images, index)

    %{
      current_index: index,
      total_count: length(images),
      media_id: image.media_id,
      image_url: image.image_url,
      alt_text: image.alt_text,
      title: image.title
    }
  end

  defp search_matches?(value, query) do
    value
    |> to_string()
    |> String.downcase()
    |> String.contains?(String.downcase(query))
  end

  defp normalize_query(value) do
    value
    |> to_string()
    |> String.trim()
  end
end
