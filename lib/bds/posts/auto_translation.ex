defmodule BDS.Posts.AutoTranslation do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Posts.PostMedia
  alias BDS.Posts.Translation
  alias BDS.Repo
  alias BDS.Tasks

  @doc """
  Schedule background auto-translation tasks for any missing target languages.

  Returns `:ok` even when nothing is scheduled (offline mode, no metadata, etc.).
  """
  @spec maybe_schedule(Post.t()) :: :ok
  def maybe_schedule(%Post{do_not_translate: true}), do: :ok

  def maybe_schedule(%Post{} = post) do
    with true <- configured?(),
         {:ok, metadata} <- Metadata.get_project_metadata(post.project_id) do
      post
      |> missing_languages(metadata)
      |> Enum.each(&queue_post(post, &1))
    else
      _other -> :ok
    end

    :ok
  end

  @doc false
  def missing_languages(%Post{} = post, metadata) do
    source_language = normalize_language(post.language || metadata.main_language)

    configured_languages =
      ([metadata.main_language] ++ (metadata.blog_languages || []))
      |> Enum.map(&normalize_language/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    existing_languages =
      Repo.all(
        from translation in Translation,
          where: translation.translation_for == ^post.id,
          select: translation.language
      )

    configured_languages
    |> Enum.reject(&(&1 == source_language or &1 in existing_languages))
  end

  defp queue_post(%Post{} = post, language) do
    _ =
      Tasks.submit_task(
        "Auto-translate Post to #{language}",
        fn report ->
          report.(0.05, "Translating post to #{language}")

          with {:ok, translation} <- AI.translate_post(post.id, language, ai_opts()),
               {:ok, saved_translation} <-
                 BDS.Posts.upsert_post_translation(post.id, language, %{
                   title: translation.title,
                   excerpt: translation.excerpt,
                   content: translation.content,
                   auto_generated: true
                 }) do
            report.(0.85, "Post translation saved")
            :ok = queue_media_cascade(post, language)
            report.(1.0, "Post translation complete")
            %{post_id: post.id, translation_id: saved_translation.id, language: language}
          else
            {:error, reason} -> {:error, reason}
          end
        end,
        task_attrs(post)
      )

    :ok
  end

  defp queue_media_cascade(%Post{} = post, language) do
    linked_media_ids(post.id)
    |> Enum.each(fn media_id ->
      if media_needed?(media_id, language) do
        queue_media(post, media_id, language)
      end
    end)

    :ok
  end

  defp queue_media(%Post{} = post, media_id, language) do
    _ =
      Tasks.submit_task(
        "Auto-translate Media to #{language}",
        fn report ->
          report.(0.05, "Translating media to #{language}")

          with {:ok, translation} <- AI.translate_media(media_id, language, ai_opts()),
               {:ok, saved_translation} <-
                 Media.upsert_media_translation(media_id, language, %{
                   title: translation.title,
                   alt: translation.alt,
                   caption: translation.caption
                 }) do
            report.(1.0, "Media translation complete")
            %{media_id: media_id, translation_id: saved_translation.id, language: language}
          else
            {:error, reason} -> {:error, reason}
          end
        end,
        task_attrs(post)
      )

    :ok
  end

  defp media_needed?(media_id, language) do
    case Repo.get(Media.Media, media_id) do
      %Media.Media{language: source_language}
      when source_language not in [nil, ""] and source_language != language ->
        not Repo.exists?(
          from translation in Media.Translation,
            where: translation.translation_for == ^media_id and translation.language == ^language
        )

      _other ->
        false
    end
  end

  defp task_attrs(%Post{} = post), do: %{group_id: post.project_id, group_name: "AI"}

  defp ai_opts do
    Application.get_env(:bds, :posts, [])
    |> Keyword.get(:auto_translation_ai_opts, [])
  end

  defp configured? do
    mode = if AI.airplane_mode?(), do: :airplane, else: :online

    case AI.get_endpoint(mode) do
      {:ok, %{url: url, model: model} = endpoint}
      when is_binary(url) and url != "" and is_binary(model) and model != "" ->
        mode == :airplane or present?(Map.get(endpoint, :api_key))

      _other ->
        false
    end
  end

  defp linked_media_ids(post_id) do
    Repo.all(
      from pm in PostMedia,
        where: pm.post_id == ^post_id,
        order_by: [asc: pm.sort_order, asc: pm.media_id],
        select: pm.media_id
    )
  end

  defp normalize_language(nil), do: ""

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
