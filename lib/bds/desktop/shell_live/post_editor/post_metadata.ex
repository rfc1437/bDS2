defmodule BDS.Desktop.ShellLive.PostEditor.PostMetadata do
  @moduledoc false

  import Ecto.Query

  alias BDS.{I18n, Media, Metadata, PostLinks, Posts, Preview, Repo, Templates}
  alias BDS.Desktop.ShellData
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.{Post, PostMedia}

  def project_metadata(nil), do: %{main_language: "en", blog_languages: []}

  def project_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    metadata
  rescue
    _error -> %{main_language: "en", blog_languages: []}
  end

  def canonical_language(post, metadata) do
    BDS.Desktop.ShellLive.PostEditor.DraftManagement.normalize_language(
      post.language,
      metadata.main_language || "en"
    )
  end

  def translations(post_id) do
    {:ok, translations} = Posts.list_post_translations(post_id)
    Map.new(translations, fn translation -> {translation.language, translation} end)
  end

  def languages(metadata) do
    (([metadata.main_language || "en"] ++ (metadata.blog_languages || [])) ++ Enum.map(I18n.supported_languages(), & &1.code))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def template_options(project_id) do
    Repo.all(
      from template in Templates.Template,
        where: template.project_id == ^project_id,
        order_by: [asc: template.title, asc: template.slug],
        select: %{slug: template.slug, title: fragment("COALESCE(?, ?)", template.title, template.slug)}
    )
  rescue
    _error -> []
  end

  def linked_media(post_id) do
    rows =
      Repo.all(
        from pm in PostMedia,
          where: pm.post_id == ^post_id,
          order_by: [asc: pm.sort_order, asc: pm.media_id],
          select: {pm.media_id, pm.sort_order}
      )

    Enum.map(rows, fn {media_id, sort_order} ->
      case Media.get_media(media_id) do
        %MediaRecord{} = media ->
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
  rescue
    _error -> []
  end

  def post_links(post_id) do
    %{
      backlinks: related_posts(PostLinks.list_incoming_links(post_id), :source_post_id),
      outlinks: related_posts(PostLinks.list_outgoing_links(post_id), :target_post_id)
    }
  end

  defp related_posts(links, key) do
    Enum.map(links, fn link ->
      case Posts.get_post(Map.fetch!(link, key)) do
        %Post{} = post -> %{id: post.id, title: post.title || post.slug || post.id, text: link.link_text || post.slug || post.id}
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def translation_flags(post, canonical_language, active_language, translations) do
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

  def footer(post, translation, active_language, canonical_language) do
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

  def display_title(title, slug, fallback_id) do
    blank_to_nil(title) || blank_to_nil(slug) || fallback_id || translated("Untitled")
  end

  def gallery_count(form) do
    form
    |> Map.get("content", "")
    |> to_string()
    |> then(&Regex.scan(~r/!\[[^\]]*\]\([^\)]+\)/, &1))
    |> length()
  end

  def preview_url(_post, _active_language, _canonical_language, mode) when mode != :preview, do: nil

  def preview_url(%Post{} = post, active_language, canonical_language, :preview) do
    query =
      %{}
      |> maybe_put_query("draft", "true")
      |> maybe_put_query("post_id", post.id)
      |> maybe_put_query("lang", active_language != canonical_language && active_language)

    Preview.base_url() <> canonical_preview_path(post.created_at, post.slug) <> "?" <> URI.encode_query(query)
  end

  defp canonical_preview_path(created_at_ms, slug) do
    datetime = DateTime.from_unix!(created_at_ms, :millisecond)
    "/#{datetime.year}/#{pad2(datetime.month)}/#{pad2(datetime.day)}/#{slug || ""}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp maybe_put_query(query, _key, false), do: query
  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  def truthy?(value) when value in [true, "true", "on", 1, "1"], do: true
  def truthy?(_value), do: false

  def blank?(value), do: blank_to_nil(value) == nil

  def blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
