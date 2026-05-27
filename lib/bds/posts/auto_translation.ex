defmodule BDS.Posts.AutoTranslation do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
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

  @doc """
  Fill missing translations for published posts and their linked media.

  This mirrors the legacy batch workflow: only published posts are scanned,
  posts marked `do_not_translate` are skipped, generated post translations are
  auto-published, and linked media translations are created for any remaining
  configured languages.
  """
  @spec fill_missing(String.t(), keyword()) ::
          {:ok,
           %{
             translated_posts: non_neg_integer(),
             translated_media: non_neg_integer(),
             failed_count: non_neg_integer(),
             warned_count: non_neg_integer(),
             nothing_to_do: boolean()
           }}
  def fill_missing(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    on_progress = Keyword.get(opts, :on_progress)

    with {:ok, metadata} <- Metadata.get_project_metadata(project_id) do
      languages = configured_languages(metadata)

      if length(languages) <= 1 do
        report_progress(on_progress, 1.0, "All translations are up to date")

        {:ok,
         %{
           translated_posts: 0,
           translated_media: 0,
           failed_count: 0,
           warned_count: 0,
           nothing_to_do: true
         }}
      else
        report_progress(on_progress, 0.0, "Scanning published posts")

        published_posts =
          Repo.all(
            from post in Post,
              where: post.project_id == ^project_id and post.status == :published,
              order_by: [asc: post.created_at, asc: post.slug]
          )

        post_languages = existing_post_languages(project_id)

        post_items =
          published_posts
          |> Enum.reject(& &1.do_not_translate)
          |> Enum.flat_map(fn post ->
            post
            |> missing_languages(metadata, Map.get(post_languages, post.id, MapSet.new()))
            |> Enum.map(&%{post: post, language: &1})
          end)

        report_progress(on_progress, 0.1, "Scanning linked media")

        media_items = collect_missing_media_items(published_posts, metadata, languages)
        total_items = length(post_items) + length(media_items)

        if total_items == 0 do
          report_progress(on_progress, 1.0, "All translations are up to date")

          {:ok,
           %{
             translated_posts: 0,
             translated_media: 0,
             failed_count: 0,
             warned_count: 0,
             nothing_to_do: true
           }}
        else
          report_progress(
            on_progress,
            0.15,
            "Found #{length(post_items)} posts and #{length(media_items)} media to translate"
          )

          {summary, completed} =
            Enum.reduce(post_items, {empty_fill_summary(), 0}, fn %{
                                                                    post: post,
                                                                    language: language
                                                                  },
                                                                  {summary, completed} ->
              report_fill_item_progress(
                on_progress,
                completed,
                total_items,
                "Translating \"#{post.title}\" to #{language}"
              )

              next_summary =
                case translate_post(post, language, auto_publish: true) do
                  {:ok, _translation} -> Map.update!(summary, :translated_posts, &(&1 + 1))
                  {:error, _reason} -> Map.update!(summary, :failed_count, &(&1 + 1))
                end

              {next_summary, completed + 1}
            end)

          {summary, _completed} =
            Enum.reduce(media_items, {summary, completed}, fn %{
                                                                media_id: media_id,
                                                                language: language
                                                              },
                                                              {summary, completed} ->
              report_fill_item_progress(
                on_progress,
                completed,
                total_items,
                "Translating media #{String.slice(media_id, 0, 8)} to #{language}"
              )

              next_summary =
                case translate_media(media_id, language) do
                  {:ok, _translation} -> Map.update!(summary, :translated_media, &(&1 + 1))
                  {:error, _reason} -> Map.update!(summary, :failed_count, &(&1 + 1))
                end

              {next_summary, completed + 1}
            end)

          final_summary = Map.put(summary, :nothing_to_do, false)
          report_progress(on_progress, 1.0, completion_message(final_summary))
          {:ok, final_summary}
        end
      end
    end
  end

  @doc false
  def missing_languages(%Post{} = post, metadata) do
    existing_languages =
      Repo.all(
        from translation in Translation,
          where: translation.translation_for == ^post.id,
          select: translation.language
      )
      |> MapSet.new()

    missing_languages(post, metadata, existing_languages)
  end

  defp queue_post(%Post{} = post, language) do
    _ =
      Tasks.submit_task(
        "Auto-translate Post to #{language}",
        fn report ->
          report.(0.05, "Translating post to #{language}")

          with {:ok, saved_translation} <- translate_post(post, language) do
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

          with {:ok, saved_translation} <- translate_media(media_id, language) do
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

  defp configured_languages(metadata) do
    ([metadata.main_language] ++ metadata.blog_languages)
    |> Enum.map(&normalize_language/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp existing_post_languages(project_id) do
    Repo.all(
      from translation in Translation,
        where: translation.project_id == ^project_id,
        select: {translation.translation_for, translation.language}
    )
    |> Enum.reduce(%{}, fn {post_id, language}, acc ->
      Map.update(acc, post_id, MapSet.new([language]), &MapSet.put(&1, language))
    end)
  end

  defp collect_missing_media_items(published_posts, metadata, languages) do
    linked_media_ids =
      published_posts
      |> Enum.reject(& &1.do_not_translate)
      |> Enum.flat_map(&linked_media_ids(&1.id))
      |> Enum.uniq()

    media_by_id =
      Repo.all(from media in Media.Media, where: media.id in ^linked_media_ids)
      |> Map.new(&{&1.id, &1})

    media_languages = existing_media_languages(linked_media_ids)

    Enum.flat_map(linked_media_ids, fn media_id ->
      case Map.get(media_by_id, media_id) do
        nil ->
          []

        media ->
          source_language = normalize_language(media.language || metadata.main_language)
          existing_languages = Map.get(media_languages, media_id, MapSet.new())

          languages
          |> Enum.reject(&(&1 == source_language or MapSet.member?(existing_languages, &1)))
          |> Enum.map(&%{media_id: media_id, language: &1})
      end
    end)
  end

  defp existing_media_languages(media_ids) do
    Repo.all(
      from translation in Media.Translation,
        where: translation.translation_for in ^media_ids,
        select: {translation.translation_for, translation.language}
    )
    |> Enum.reduce(%{}, fn {media_id, language}, acc ->
      Map.update(acc, media_id, MapSet.new([language]), &MapSet.put(&1, language))
    end)
  end

  defp empty_fill_summary do
    %{
      translated_posts: 0,
      translated_media: 0,
      failed_count: 0,
      warned_count: 0,
      nothing_to_do: false
    }
  end

  defp completion_message(summary) do
    extras =
      []
      |> maybe_add_completion_detail(summary.failed_count, "failed")
      |> maybe_add_completion_detail(summary.warned_count, "warnings")

    if extras == [] do
      "Done"
    else
      "Done (#{Enum.join(extras, ", ")})"
    end
  end

  defp maybe_add_completion_detail(details, 0, _label), do: details

  defp maybe_add_completion_detail(details, count, label) do
    details ++ ["#{count} #{label}"]
  end

  defp report_fill_item_progress(on_progress, completed, total_items, message) do
    progress = 0.15 + completed / total_items * 0.85
    report_progress(on_progress, progress, message)
  end

  defp report_progress(on_progress, value, message) when is_function(on_progress, 2) do
    on_progress.(value, message)
  end

  defp report_progress(_on_progress, _value, _message), do: :ok

  defp missing_languages(%Post{} = post, metadata, existing_languages) do
    source_language = normalize_language(post.language || metadata.main_language)

    configured_languages(metadata)
    |> Enum.reject(&(&1 == source_language or MapSet.member?(existing_languages, &1)))
  end

  defp translate_post(%Post{} = post, language, opts \\ []) do
    auto_publish? = Keyword.get(opts, :auto_publish, false)
    content = Posts.editor_body(post)
    source_language = normalize_language(post.language)

    if String.trim(content) == "" do
      {:error, :no_content_to_translate}
    else
      with {:ok, translation} <-
             AI.translate_post(
               %{title: post.title || "", excerpt: post.excerpt || "", content: content},
               language,
               Keyword.put(ai_opts(), :source_language, source_language)
             ),
           {:ok, saved_translation} <-
             Posts.upsert_post_translation(post.id, language, %{
               title: translation.title,
               excerpt: translation.excerpt,
               content: translation.content,
               auto_generated: true
             }),
           {:ok, published_translation} <-
             maybe_publish_post_translation(post.id, language, saved_translation, auto_publish?) do
        {:ok, published_translation}
      end
    end
  end

  defp maybe_publish_post_translation(_post_id, _language, saved_translation, false),
    do: {:ok, saved_translation}

  defp maybe_publish_post_translation(post_id, language, _saved_translation, true),
    do: Posts.publish_post_translation(post_id, language)

  defp translate_media(media_id, language) do
    source_language =
      case Repo.get(Media.Media, media_id) do
        nil -> ""
        media -> normalize_language(media.language)
      end

    with {:ok, translation} <-
           AI.translate_media(
             media_id,
             language,
             Keyword.put(ai_opts(), :source_language, source_language)
           ),
         {:ok, saved_translation} <-
           Media.upsert_media_translation(media_id, language, %{
             title: translation.title,
             alt: translation.alt,
             caption: translation.caption
           }) do
      {:ok, saved_translation}
    end
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
