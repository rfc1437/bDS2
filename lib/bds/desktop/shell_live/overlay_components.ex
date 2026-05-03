defmodule BDS.Desktop.ShellLive.OverlayComponents do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query

  alias BDS.Desktop.ShellData
  alias BDS.{I18n, Media, Metadata, Posts, Repo}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Posts.{Post, PostMedia, Translation}
  alias BDS.Tags.Tag

  embed_templates("overlay_html/*")

  def context(assigns, tab_title, tab_subtitle) do
    project_id = assigns.projects.active_project_id
    metadata = project_metadata(project_id)
    current_tab = assigns.current_tab
    page_language = assigns.page_language
    posts = posts(project_id)
    media = media(project_id)

    %{
      current_tab: %{
        type: current_tab.type,
        id: current_tab.id,
        title: tab_title,
        subtitle: tab_subtitle
      },
      current_post_language: source_language(current_tab, metadata),
      current_media_language: source_language(current_tab, metadata),
      posts: posts,
      media: media,
      post_media_ids: post_media_ids(current_tab),
      blog_languages: blog_languages(metadata),
      language_names: language_names(),
      language_flags: language_flags(),
      existing_translations: existing_translations(current_tab),
      ai_title: ShellData.translate("AI Suggestions", %{}, page_language),
      insert_link_title: ShellData.translate("Insert Link", %{}, page_language),
      insert_media_title: ShellData.translate("Insert Media", %{}, page_language),
      language_picker_title: ShellData.translate("Translate", %{}, page_language),
      gallery_title: tab_title,
      ai_fields: ai_fields(current_tab, tab_title, tab_subtitle, page_language),
      delete_details: delete_details(current_tab, page_language),
      merge_details: merge_details(project_id, page_language)
    }
  end

  def kind("ai_suggestions"), do: :ai_suggestions
  def kind("insert_link"), do: :insert_link
  def kind("insert_media"), do: :insert_media
  def kind("language_picker"), do: :language_picker
  def kind("confirm_delete"), do: :confirm_delete
  def kind("confirm_merge"), do: :confirm_merge
  def kind("gallery"), do: :gallery
  def kind(_kind), do: nil

  def tab("internal"), do: :internal
  def tab("external"), do: :external
  def tab(_tab), do: :internal

  def markdown_link(text, url), do: "[#{text}](#{url})"

  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  def project_metadata(nil), do: %{main_language: "en", blog_languages: []}

  def project_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    metadata
  rescue
    _error -> %{main_language: "en", blog_languages: []}
  end

  defp posts(nil), do: []

  defp posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at, desc: post.created_at],
        select: %{
          id: post.id,
          title: post.title,
          slug: post.slug,
          status: post.status,
          published_at: post.published_at,
          updated_at: post.updated_at,
          language: post.language
        }
    )
    |> Enum.map(fn post ->
      %{
        id: post.id,
        title: post.title || post.slug || post.id,
        status: Atom.to_string(post.status || :draft),
        canonical_url: canonical_post_url(post)
      }
    end)
  end

  defp media(nil), do: []

  defp media(project_id) do
    Repo.all(
      from media in MediaRecord,
        where: media.project_id == ^project_id,
        order_by: [desc: media.updated_at, desc: media.created_at],
        select: %{
          id: media.id,
          title: media.title,
          original_name: media.original_name,
          mime_type: media.mime_type,
          alt: media.alt,
          caption: media.caption
        }
    )
    |> Enum.map(fn media ->
      %{
        id: media.id,
        title: media.title || media.original_name || media.id,
        original_name: media.original_name || media.id,
        is_image: String.starts_with?(to_string(media.mime_type || ""), "image/"),
        thumbnail_url: "/media-thumbnail/#{media.id}",
        image_url: "/media-thumbnail/#{media.id}?size=large",
        alt_text: media.alt || media.caption || media.title
      }
    end)
  end

  defp post_media_ids(%{type: :post, id: post_id}) do
    Repo.all(
      from pm in PostMedia,
        where: pm.post_id == ^post_id,
        order_by: [asc: pm.sort_order, asc: pm.media_id],
        select: pm.media_id
    )
  rescue
    _error -> []
  end

  defp post_media_ids(_tab), do: []

  defp existing_translations(%{type: :post, id: post_id}) do
    Repo.all(
      from translation in Translation,
        where: translation.translation_for == ^post_id,
        select: {translation.language, translation.status}
    )
    |> Map.new(fn {language, status} -> {language, Atom.to_string(status || :draft)} end)
  rescue
    _error -> %{}
  end

  defp existing_translations(%{type: :media, id: media_id}) do
    Repo.all(
      from translation in MediaTranslation,
        where: translation.translation_for == ^media_id,
        select: {translation.language, "draft"}
    )
    |> Map.new(fn {language, status} -> {language, status} end)
  rescue
    _error -> %{}
  end

  defp existing_translations(_tab), do: %{}

  defp blog_languages(metadata) do
    ([metadata.main_language || "en"] ++
       (metadata.blog_languages || []) ++ Enum.map(I18n.supported_languages(), & &1.code))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp source_language(%{type: :post, id: post_id}, metadata) do
    case Posts.get_post(post_id) do
      %Post{language: language} when is_binary(language) and language != "" -> language
      _other -> metadata.main_language || "en"
    end
  rescue
    _error -> metadata.main_language || "en"
  end

  defp source_language(%{type: :media, id: media_id}, metadata) do
    case Media.get_media(media_id) do
      %MediaRecord{language: language} when is_binary(language) and language != "" -> language
      _other -> metadata.main_language || "en"
    end
  rescue
    _error -> metadata.main_language || "en"
  end

  defp source_language(_tab, metadata), do: metadata.main_language || "en"

  defp language_names do
    %{
      "en" => "English",
      "de" => "Deutsch",
      "fr" => "Francais",
      "it" => "Italiano",
      "es" => "Espanol"
    }
  end

  defp language_flags do
    I18n.supported_languages()
    |> Enum.into(%{}, fn language -> {language.code, I18n.flag(language.code)} end)
  end

  defp ai_fields(%{type: :post, id: post_id}, title, subtitle, page_language) do
    case Posts.get_post(post_id) do
      %Post{} = post ->
        [
          %{
            key: "title",
            label: ShellData.translate("Title", %{}, page_language),
            current_value: post.title || title,
            suggested_value: "",
            locked: false,
            loading: true
          },
          %{
            key: "excerpt",
            label: ShellData.translate("Excerpt", %{}, page_language),
            current_value: post.excerpt || subtitle,
            suggested_value: "",
            locked: false,
            loading: true
          },
          %{
            key: "slug",
            label: ShellData.translate("Slug", %{}, page_language),
            current_value: post.slug || slugify(post.title || title),
            suggested_value: "",
            locked: post.status == :published,
            loading: true
          }
        ]

      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp ai_fields(%{type: :media, id: media_id}, title, _subtitle, page_language) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media ->
        [
          %{
            key: "title",
            label: ShellData.translate("Title", %{}, page_language),
            current_value: media.title || title,
            suggested_value: "",
            locked: false,
            loading: true
          },
          %{
            key: "alt",
            label: ShellData.translate("Alt Text", %{}, page_language),
            current_value: media.alt || "",
            suggested_value: "",
            locked: false,
            loading: true
          },
          %{
            key: "caption",
            label: ShellData.translate("Caption", %{}, page_language),
            current_value: media.caption || "",
            suggested_value: "",
            locked: false,
            loading: true
          }
        ]

      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp ai_fields(_tab, _title, _subtitle, _page_language), do: []

  defp delete_details(%{type: :media, id: media_id}, page_language) do
    entity_name =
      case Media.get_media(media_id) do
        %MediaRecord{} = media -> media.title || media.original_name || media.id
        _other -> media_id
      end

    reference_list =
      Repo.all(
        from post in Post,
          join: pm in PostMedia,
          on: pm.post_id == post.id,
          where: pm.media_id == ^media_id,
          order_by: [asc: pm.sort_order, desc: post.updated_at],
          select: post.title
      )
      |> Enum.map(&(&1 || media_id))

    %{
      title: ShellData.translate("Delete Media", %{}, page_language),
      entity_name: entity_name,
      entity_type: "media",
      reference_list: reference_list
    }
  rescue
    _error ->
      %{
        title: ShellData.translate("Delete Media", %{}, page_language),
        entity_name: media_id,
        entity_type: "media",
        reference_list: []
      }
  end

  defp delete_details(%{type: :tags}, page_language) do
    tag_name =
      Repo.one(from tag in Tag, order_by: [asc: tag.name], limit: 1, select: tag.name)
      |> Kernel.||("tag")

    %{
      title: ShellData.translate("Delete Tag", %{}, page_language),
      entity_name: tag_name,
      entity_type: "tag",
      reference_list: []
    }
  rescue
    _error ->
      %{
        title: ShellData.translate("Delete Tag", %{}, page_language),
        entity_name: "tag",
        entity_type: "tag",
        reference_list: []
      }
  end

  defp delete_details(_tab, page_language) do
    %{
      title: ShellData.translate("Delete", %{}, page_language),
      entity_name: "",
      entity_type: "item",
      reference_list: []
    }
  end

  defp merge_details(project_id, page_language) do
    tags =
      Repo.all(
        from tag in Tag,
          where: tag.project_id == ^project_id,
          order_by: [asc: tag.name],
          limit: 3,
          select: tag.name
      )

    target = List.first(tags) || "tag"

    %{
      target: target,
      count: max(length(tags), 1),
      title: ShellData.translate("Merge Tags", %{}, page_language),
      message: ShellData.translate("Cannot be undone.", %{}, page_language)
    }
  rescue
    _error ->
      %{
        target: "tag",
        count: 1,
        title: ShellData.translate("Merge Tags", %{}, page_language),
        message: ShellData.translate("Cannot be undone.", %{}, page_language)
      }
  end

  defp canonical_post_url(post) do
    timestamp = post.published_at || post.updated_at || System.system_time(:millisecond)
    date = DateTime.from_unix!(timestamp, :millisecond)
    "/#{date.year}/#{pad2(date.month)}/#{pad2(date.day)}/#{post.slug || post.id}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
