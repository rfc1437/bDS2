defmodule BDS.UI.PostEditor.Draft do
  @moduledoc """
  Pure draft/form logic for the post editor (issue #26, phase 3).

  Shared by the LiveView shell and the TUI: builds the persisted form for a
  post (canonical language or translation), normalizes editor params, and
  provides the small pure helpers both renderers need. No socket, no
  process state — callers own the draft maps.
  """

  alias BDS.Posts
  alias BDS.Posts.{Post, Translation}
  alias BDS.UI.PostEditor.Metadata

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
      "language" =>
        if(current_language == next_language,
          do: normalize_language(Map.get(params, "language"), current_language),
          else: next_language
        ),
      "do_not_translate" => truthy?(Map.get(params, "do_not_translate")),
      "template_slug" => Map.get(params, "template_slug", "")
    }
  end

  def persisted_form(%Post{} = post, metadata, active_language) do
    persisted_form(post, metadata, active_language, Metadata.translations(post.id))
  end

  def persisted_form(post, metadata, active_language, translations) do
    canonical_language = Metadata.canonical_language(post, metadata)
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

  def save_state_for_action(:publish), do: :published
  def save_state_for_action(_action), do: :saved

  def record_title(%Translation{title: title}, post),
    do: blank_to_nil(title) || post.title || post.slug || post.id

  def record_title(%Post{title: title, slug: slug, id: id}, _post),
    do: blank_to_nil(title) || blank_to_nil(slug) || id

  def record_status(%Translation{status: status}), do: status || :draft
  def record_status(%Post{status: status}), do: status || :draft

  def editing_canonical_language?(translations, active_language, canonical_language) do
    active_language == canonical_language or not Map.has_key?(translations, active_language)
  end

  defp truthy?(value), do: BDS.Values.truthy?(value)

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
