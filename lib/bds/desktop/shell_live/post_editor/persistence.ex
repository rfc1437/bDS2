defmodule BDS.Desktop.ShellLive.PostEditor.Persistence do
  @moduledoc false

  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Desktop.ShellLive.PostEditor.{DraftManagement, PostMetadata}
  use Gettext, backend: BDS.Gettext

  @spec persist(term(), term(), term(), term(), term()) :: term()
  def persist(%Post{} = post, draft, active_language, metadata, action) do
    canonical_language = PostMetadata.canonical_language(post, metadata)
    translations = PostMetadata.translations(post.id)

    if DraftManagement.editing_canonical_language?(
         translations,
         active_language,
         canonical_language
       ) do
      post
      |> save_canonical_draft(draft, action)
      |> maybe_publish_post(post.id, action)
    else
      post.id
      |> save_translation_draft(active_language, draft)
      |> maybe_publish_translation(post.id, active_language, action)
    end
  end

  @spec discard(term(), term(), term()) :: term()
  def discard(%Post{} = post, active_language, metadata) do
    canonical_language = PostMetadata.canonical_language(post, metadata)
    current_translations = PostMetadata.translations(post.id)

    cond do
      not DraftManagement.editing_canonical_language?(
        current_translations,
        active_language,
        canonical_language
      ) ->
        {:ok, post}

      post.file_path not in [nil, ""] and post.status == :draft ->
        Posts.discard_post_changes(post.id)

      true ->
        {:ok, post}
    end
  end

  @spec has_published_version?(term()) :: term()
  def has_published_version?(%Post{} = post),
    do: not is_nil(post.published_at) or post.file_path not in [nil, ""]

  @spec discard_label(term()) :: term()
  def discard_label(%Post{} = post) do
    if has_published_version?(post),
      do: dgettext("ui", "Discard Changes"),
      else: dgettext("ui", "Discard Draft")
  end

  @spec discard_title(term()) :: term()
  def discard_title(%Post{} = post) do
    if has_published_version?(post),
      do: dgettext("ui", "Discard changes and restore the published version"),
      else: dgettext("ui", "Delete this unpublished draft")
  end

  defp save_canonical_draft(%Post{id: post_id}, draft, action) do
    Posts.update_post(
      post_id,
      %{
        title: blank_to_nil(Map.get(draft, "title")),
        excerpt: blank_to_nil(Map.get(draft, "excerpt")),
        content: blank_to_nil(Map.get(draft, "content")),
        tags: csv_to_list(Map.get(draft, "tags")),
        categories: csv_to_list(Map.get(draft, "categories")),
        author: blank_to_nil(Map.get(draft, "author")),
        language: blank_to_nil(Map.get(draft, "language")),
        do_not_translate: Map.get(draft, "do_not_translate", false),
        template_slug: blank_to_nil(Map.get(draft, "template_slug"))
      },
      auto_translate: action != :auto_save
    )
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
end
