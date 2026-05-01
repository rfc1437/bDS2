defmodule BDS.Desktop.ShellLive.PostEditor.Persistence do
  @moduledoc false

  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.PostEditor.{DraftManagement, PostMetadata}

  def persist(%Post{} = post, draft, active_language, metadata, action) do
    canonical_language = PostMetadata.canonical_language(post, metadata)
    translations = PostMetadata.translations(post.id)

    if DraftManagement.editing_canonical_language?(translations, active_language, canonical_language) do
      post
      |> save_canonical_draft(draft)
      |> maybe_publish_post(post.id, action)
    else
      post.id
      |> save_translation_draft(active_language, draft)
      |> maybe_publish_translation(post.id, active_language, action)
    end
  end

  def discard(%Post{} = post, active_language, metadata) do
    canonical_language = PostMetadata.canonical_language(post, metadata)
    current_translations = PostMetadata.translations(post.id)

    cond do
      not DraftManagement.editing_canonical_language?(current_translations, active_language, canonical_language) ->
        {:ok, post}

      post.file_path not in [nil, ""] and post.status == :draft ->
        Posts.discard_post_changes(post.id)

      true ->
        {:ok, post}
    end
  end

  def has_published_version?(%Post{} = post),
    do: not is_nil(post.published_at) or post.file_path not in [nil, ""]

  def discard_label(%Post{} = post) do
    if has_published_version?(post),
      do: translated("Discard Changes"),
      else: translated("Discard Draft")
  end

  def discard_title(%Post{} = post) do
    if has_published_version?(post),
      do: translated("Discard changes and restore the published version"),
      else: translated("Delete this unpublished draft")
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

  defp maybe_publish_translation({:ok, _translation}, post_id, language, :publish),
    do: Posts.publish_post_translation(post_id, language)

  defp maybe_publish_translation(result, _post_id, _language, _action), do: result

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

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end
