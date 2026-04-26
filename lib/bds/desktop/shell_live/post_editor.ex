defmodule BDS.Desktop.ShellLive.PostEditor do
  @moduledoc false

  use Phoenix.Component

  import Ecto.Query
  import Phoenix.HTML

  alias BDS.Desktop.ShellData
  alias BDS.{I18n, PostLinks, Posts, Repo, Tags, Templates}
  alias BDS.Media.Media
  alias BDS.Posts.{Post, Translation}
  alias BDS.UI.Workbench

  embed_templates "post_editor_html/*"

  def build(%{current_tab: %{type: :post, id: post_id}} = assigns) do
    case Repo.get(Post, post_id) do
      nil ->
        nil

      %Post{} = post ->
        metadata = project_metadata(assigns)
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
          subtitle: active_language_subtitle(active_language, canonical_language),
          slug: post.slug || post.id,
          status: current_status(post.status, active_language, canonical_language, current_translation),
          dirty?: Workbench.dirty?(assigns.workbench, :post, post.id),
          save_state: Map.get(assigns.post_editor_save_states, post.id, :idle),
          metadata_expanded: Map.get(expanded, :metadata, false),
          excerpt_expanded: Map.get(expanded, :excerpt, false),
          mode: Map.get(assigns.post_editor_modes, post.id, :markdown),
          editing_canonical?: editing_canonical_language?(translations, active_language, canonical_language),
          languages: languages(metadata),
          form: form,
          template_options: template_options(post.project_id),
          tag_options: Enum.map(Tags.list_tags(post.project_id), & &1.name),
          category_options: metadata.categories || [],
          translation_flags: translation_flags(post, canonical_language, active_language, translations),
          linked_media: linked_media(post.id),
          post_links: post_links(post.id),
          footer: footer(post, current_translation, active_language, canonical_language)
        }
    end
  end

  def build(_assigns), do: nil

  def normalize_mode(mode) when mode in [:visual, :markdown, :preview], do: mode
  def normalize_mode("visual"), do: :visual
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

  def post_editor_mode_label(:visual), do: translated("Visual")
  def post_editor_mode_label(:markdown), do: translated("Markdown")
  def post_editor_mode_label(:preview), do: translated("Preview")

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  defp editor_toolbar(assigns) do
    ~H"""
    <%= if Enum.any?(@toolbar_buttons) do %>
      <div class="editor-toolbar">
        <%= for button <- @toolbar_buttons do %>
          <button
            class={["editor-toolbar-button", if(button.destructive, do: "is-destructive")]}
            data-testid="editor-toolbar-overlay-button"
            type="button"
            phx-click="open_overlay"
            phx-value-kind={button.kind}
          >
            <%= translated(button.label) %>
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp project_metadata(assigns), do: Map.get(assigns, :project_metadata, %{})

  defp current_status(post_status, active_language, canonical_language, current_translation) do
    if active_language == canonical_language, do: post_status, else: translation_status(current_translation)
  end

  defp persisted_form(post, metadata, active_language, translations) do
    canonical_language = canonical_language(post, metadata)
    translation = Map.get(translations, active_language)

    if active_language == canonical_language do
      %{
        "title" => post.title || "",
        "excerpt" => post.excerpt || "",
        "content" => post.content || "",
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
        "content" => translation && translation.content || "",
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

  defp translation_status(nil), do: :draft
  defp translation_status(%Translation{status: status}) when not is_nil(status), do: status
  defp translation_status(_translation), do: :draft

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

  defp active_language_subtitle(active_language, canonical_language) do
    if active_language == canonical_language do
      translated("Canonical draft")
    else
      translated("Translation: %{language}", %{language: String.upcase(active_language)})
    end
  end

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
end