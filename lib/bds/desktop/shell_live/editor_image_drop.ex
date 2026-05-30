defmodule BDS.Desktop.ShellLive.EditorImageDrop do
  @moduledoc false

  # Implements the drag-and-drop image chain described in
  # action_patterns.allium DragDropImageChain (trigger: editor_post.allium
  # PostDragDropImage). A single image file dropped on the post editor body
  # runs four synchronous steps the user waits on, then two background steps
  # whose results are auto-applied without a modal.

  require Logger

  alias BDS.{AI, Media, Metadata, Posts}

  @doc """
  Synchronous portion of the chain (steps 1-4):

    1. importMedia(file) -> media record + file copy + base sidecar
    2. generateThumbnails(media) -> small/medium/large/ai (done inside import_media)
    3. linkMediaToPost(media, post) -> update sidecar linkedPostIds
    4. caller inserts the returned markdown at the cursor

  Returns `{:ok, media, markdown}` where `markdown` is the reference inserted at
  the cursor. These steps are not AI activities, so they run regardless of
  airplane mode.
  """
  @spec import_and_link(String.t(), String.t(), String.t()) ::
          {:ok, Media.Media.t(), String.t()} | {:error, term()}
  def import_and_link(project_id, post_id, source_path) do
    with {:ok, media} <-
           Media.import_media(%{project_id: project_id, source_path: source_path}),
         {:ok, _link} <- Media.link_media_to_post(media.id, post_id) do
      {:ok, media, markdown_for(media)}
    end
  end

  @doc """
  Markdown reference inserted at the cursor (step 4): `![](bds-media://id)` for
  images, a plain link for other file types.
  """
  @spec markdown_for(Media.Media.t()) :: String.t()
  def markdown_for(media) do
    if String.starts_with?(media.mime_type || "", "image/") do
      "![](bds-media://#{media.id})"
    else
      "[#{media.original_name}](bds-media://#{media.id})"
    end
  end

  @doc """
  Background portion of the chain (steps 5-6), gated behind airplane mode:

    5. aiImageAnalysis(media) -> results auto-applied to media metadata (no modal)
    6. if auto-translate enabled (post.do_not_translate == false):
         translateMediaMetadata(media, lang) for each blog language

  Only runs for images. Failures are logged and never roll back the import.
  """
  @spec enrich(Media.Media.t(), String.t(), String.t()) :: :ok
  def enrich(media, post_id, language) do
    if image?(media) do
      with {:ok, result} <- AI.analyze_image(media.id, language: language),
           {:ok, _updated} <-
             Media.update_media(media.id, %{
               title: result.title,
               alt: result.alt,
               caption: result.caption
             }) do
        maybe_translate(media.id, post_id, language)
      else
        {:error, reason} ->
          Logger.warning("Drag-drop AI analysis failed for #{media.id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp maybe_translate(media_id, post_id, language) do
    post = Posts.get_post(post_id)

    if post && not post.do_not_translate do
      translate_targets(post.project_id, language)
      |> Enum.each(fn target ->
        case AI.translate_media(media_id, target) do
          {:ok, translation} ->
            Media.upsert_media_translation(media_id, target, %{
              title: translation.title,
              alt: translation.alt,
              caption: translation.caption
            })

          {:error, reason} ->
            Logger.warning(
              "Drag-drop media translation failed for #{media_id} -> #{target}: #{inspect(reason)}"
            )
        end
      end)
    end
  end

  defp translate_targets(project_id, language) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    [metadata.main_language | metadata.blog_languages || []]
    |> Enum.reject(&(&1 == language or is_nil(&1)))
    |> Enum.uniq()
  end

  defp image?(media), do: String.starts_with?(media.mime_type || "", "image/")
end
