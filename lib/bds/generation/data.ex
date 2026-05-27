defmodule BDS.Generation.Data do
  @moduledoc false

  import BDS.Generation.Paths, only: [local_date_parts!: 1]
  import BDS.Generation.Progress, only: [report_snapshot_stage_progress: 4]

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Repo

  import Ecto.Query

  @spec generation_data(map(), keyword()) :: map()
  def generation_data(plan, opts \\ []) do
    project = Projects.get_project!(plan.project_id)
    project_data_dir = Projects.project_data_dir(project)
    list_excluded_categories = excluded_list_categories(plan)
    on_snapshot_progress = Keyword.get(opts, :on_snapshot_progress)

    published_candidates =
      Repo.all(
        from post in Post,
          where: post.project_id == ^plan.project_id and post.status == :published,
          order_by: [desc: post.created_at, desc: post.published_at, asc: post.slug]
      )

    draft_candidates =
      Repo.all(
        from post in Post,
          where: post.project_id == ^plan.project_id and post.status == :draft,
          order_by: [desc: post.created_at, desc: post.published_at, asc: post.slug]
      )

    post_snapshot_candidates = published_candidates ++ draft_candidates

    snapshots_by_id =
      post_snapshot_candidates
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {post, index}, acc ->
        :ok =
          report_snapshot_stage_progress(
            on_snapshot_progress,
            :posts,
            index,
            length(post_snapshot_candidates)
          )

        case published_post_snapshot(project_data_dir, post) do
          nil -> acc
          snapshot -> Map.put(acc, post.id, snapshot)
        end
      end)

    published_posts =
      published_candidates
      |> merge_generation_snapshots(snapshots_by_id)
      |> then(fn published ->
        draft_candidates
        |> merge_generation_snapshots(snapshots_by_id)
        |> Enum.reduce(Map.new(published, &{&1.id, &1}), fn post, acc ->
          Map.put(acc, post.id, post)
        end)
        |> Map.values()
      end)
      |> Enum.sort_by(&{-(&1.created_at || 0), -(&1.published_at || 0), to_string(&1.slug)})

    published_list_posts =
      (published_candidates ++ draft_candidates)
      |> Enum.reject(fn post -> list_excluded_post?(post, list_excluded_categories) end)
      |> merge_generation_snapshots(snapshots_by_id)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{-(&1.created_at || 0), -(&1.published_at || 0), to_string(&1.slug)})

    {published_route_posts, translations_by_post} =
      build_generation_route_posts(
        plan.project_id,
        project_data_dir,
        published_posts,
        on_snapshot_progress
      )

    %{
      project: project,
      project_data_dir: project_data_dir,
      published_posts: published_posts,
      published_list_posts: published_list_posts,
      published_route_posts: published_route_posts,
      translations_by_post: translations_by_post,
      post_index: build_generation_post_index(published_list_posts)
    }
  end

  @spec flattened_generation_translations(map()) :: [Translation.t() | map()]
  def flattened_generation_translations(translations_by_post) do
    translations_by_post
    |> Map.values()
    |> List.flatten()
  end

  @spec translation_lookup_map([Translation.t() | map()]) :: map()
  def translation_lookup_map(published_translations) do
    Map.new(published_translations, fn translation ->
      {{translation.translation_for, translation.language}, translation}
    end)
  end

  @spec resolve_posts_for_language([map()], String.t() | nil, map(), String.t() | nil) :: [map()]
  def resolve_posts_for_language(
        posts,
        target_language,
        translations_by_post_language,
        main_language
      ) do
    target = String.downcase(to_string(target_language || ""))
    main = String.downcase(to_string(main_language || ""))

    Enum.map(posts, fn post ->
      post_language = String.downcase(to_string(post.language || ""))
      effective_language = if post_language == "", do: main, else: post_language

      cond do
        is_binary(Map.get(post, :translation_source_slug)) ->
          post

        effective_language == target ->
          post

        true ->
          case Map.get(translations_by_post_language, {post.id, target_language}) do
            nil -> post
            translation -> build_localized_subtree_variant(post, translation)
          end
      end
    end)
  end

  @spec build_generation_post_index([map()]) :: map()
  def build_generation_post_index(posts) do
    Enum.reduce(
      posts,
      %{
        posts_by_category: %{},
        posts_by_tag: %{},
        posts_by_year: %{},
        posts_by_year_month: %{},
        posts_by_year_month_day: %{}
      },
      fn post, acc ->
        {year, month_value, day_value} = local_date_parts!(post.created_at)
        month = String.pad_leading(Integer.to_string(month_value), 2, "0")
        day = String.pad_leading(Integer.to_string(day_value), 2, "0")
        year_month = "#{year}/#{month}"
        year_month_day = "#{year}/#{month}/#{day}"

        acc
        |> append_generation_index(:posts_by_year, year, post)
        |> append_generation_index(:posts_by_year_month, year_month, post)
        |> append_generation_index(:posts_by_year_month_day, year_month_day, post)
        |> then(fn indexed ->
          indexed =
            Enum.reduce(
              post.categories || [],
              indexed,
              &append_generation_index(&2, :posts_by_category, &1, post)
            )

          Enum.reduce(
            post.tags || [],
            indexed,
            &append_generation_index(&2, :posts_by_tag, &1, post)
          )
        end)
      end
    )
  end

  ## --- internals -----------------------------------------------------------

  defp merge_generation_snapshots(posts, snapshots_by_id) do
    posts
    |> Enum.map(&Map.get(snapshots_by_id, &1.id))
    |> Enum.reject(&is_nil/1)
  end

  defp excluded_list_categories(plan) do
    plan
    |> resolved_category_settings()
    |> Enum.filter(fn {_category, settings} -> settings.render_in_lists == false end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp resolved_category_settings(plan) do
    defaults = %{
      "article" => %{render_in_lists: true, show_title: true},
      "picture" => %{render_in_lists: true, show_title: true},
      "aside" => %{render_in_lists: true, show_title: false},
      "page" => %{render_in_lists: false, show_title: true}
    }

    Enum.reduce(Map.get(plan, :category_settings, %{}) || %{}, defaults, fn {category, settings},
                                                                            acc ->
      Map.put(acc, category, %{
        render_in_lists:
          category_setting_flag(settings, :render_in_lists, "render_in_lists", true),
        show_title: category_setting_flag(settings, :show_title, "show_title", true)
      })
    end)
  end

  defp category_setting_flag(settings, atom_key, string_key, default) do
    case Map.get(settings, atom_key, Map.get(settings, string_key, default)) do
      false -> false
      _other -> true
    end
  end

  defp list_excluded_post?(post, excluded_categories) do
    Enum.any?(post.categories || [], &MapSet.member?(excluded_categories, &1))
  end

  defp published_post_snapshot(project_data_dir, %Post{} = post) do
    cond do
      is_binary(post.file_path) and post.file_path != "" ->
        project_data_dir
        |> Path.join(post.file_path)
        |> read_post_snapshot(post)

      post.status == :published ->
        post

      true ->
        nil
    end
  end

  defp read_post_snapshot(full_path, %Post{} = fallback_post) do
    case File.read(full_path) do
      {:ok, contents} ->
        {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)

        %Post{
          fallback_post
          | id: DocumentFields.get(fields, "id", fallback_post.id),
            title: DocumentFields.get(fields, "title", fallback_post.title) || "",
            slug: DocumentFields.fetch!(fields, "slug"),
            excerpt: Map.get(fields, "excerpt"),
            content: nil,
            status: :published,
            author: Map.get(fields, "author"),
            language: Map.get(fields, "language", fallback_post.language),
            do_not_translate:
              DocumentFields.get(
                fields,
                "doNotTranslate",
                fallback_post.do_not_translate || false
              ),
            template_slug:
              DocumentFields.get(fields, "templateSlug", fallback_post.template_slug),
            created_at: DocumentFields.get(fields, "createdAt", fallback_post.created_at),
            updated_at: DocumentFields.get(fields, "updatedAt", fallback_post.updated_at),
            published_at: DocumentFields.get(fields, "publishedAt", fallback_post.published_at),
            file_path: fallback_post.file_path,
            tags: Map.get(fields, "tags", fallback_post.tags || []),
            categories: Map.get(fields, "categories", fallback_post.categories || [])
        }

      {:error, _reason} ->
        if fallback_post.status == :published, do: fallback_post, else: nil
    end
  end

  defp build_generation_route_posts(
         project_id,
         project_data_dir,
         published_posts,
         on_snapshot_progress
       ) do
    source_post_ids = Enum.map(published_posts, & &1.id)

    translation_candidates =
      Repo.all(
        from translation in Translation,
          where:
            translation.project_id == ^project_id and
              translation.translation_for in ^source_post_ids,
          where: translation.status in [:published, :draft],
          order_by: [asc: translation.translation_for, asc: translation.language]
      )

    translations_by_post =
      translation_candidates
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {translation, index}, acc ->
        :ok =
          report_snapshot_stage_progress(
            on_snapshot_progress,
            :translations,
            index,
            length(translation_candidates)
          )

        case published_translation_snapshot(project_data_dir, translation) do
          nil -> acc
          snapshot -> Map.update(acc, translation.translation_for, [snapshot], &[snapshot | &1])
        end
      end)
      |> Map.new(fn {post_id, translations} -> {post_id, Enum.reverse(translations)} end)

    route_posts =
      Enum.flat_map(published_posts, fn post ->
        variants =
          translations_by_post
          |> Map.get(post.id, [])
          |> Enum.map(&build_published_translation_variant(post, &1))

        [post | variants]
      end)

    {route_posts, translations_by_post}
  end

  defp published_translation_snapshot(project_data_dir, %Translation{} = translation) do
    cond do
      is_binary(translation.file_path) and translation.file_path != "" ->
        project_data_dir
        |> Path.join(translation.file_path)
        |> read_translation_snapshot(translation)

      translation.status == :published ->
        translation

      true ->
        nil
    end
  end

  defp read_translation_snapshot(full_path, %Translation{} = fallback_translation) do
    case File.read(full_path) do
      {:ok, contents} ->
        {:ok, %{fields: fields}} = Frontmatter.parse_document(contents)

        %Translation{
          fallback_translation
          | id: DocumentFields.get(fields, "id", fallback_translation.id),
            translation_for: DocumentFields.fetch!(fields, "translationFor"),
            language: DocumentFields.fetch!(fields, "language"),
            title: DocumentFields.get(fields, "title", fallback_translation.title) || "",
            excerpt: Map.get(fields, "excerpt", fallback_translation.excerpt),
            content: nil,
            status: :published,
            created_at: DocumentFields.get(fields, "createdAt", fallback_translation.created_at),
            updated_at: DocumentFields.get(fields, "updatedAt", fallback_translation.updated_at),
            published_at:
              DocumentFields.get(fields, "publishedAt", fallback_translation.published_at),
            file_path: fallback_translation.file_path
        }

      {:error, _reason} ->
        if fallback_translation.status == :published, do: fallback_translation, else: nil
    end
  end

  defp build_published_translation_variant(post, translation) do
    %{
      id: translation.id,
      project_id: post.project_id,
      title: translation.title,
      slug: "#{post.slug}.#{translation.language}",
      excerpt: translation.excerpt,
      content: nil,
      status: :published,
      author: post.author,
      created_at: post.created_at,
      updated_at: translation.updated_at,
      published_at: translation.published_at || post.published_at,
      file_path: translation.file_path,
      tags: post.tags,
      categories: post.categories,
      template_slug: post.template_slug,
      language: translation.language,
      do_not_translate: post.do_not_translate,
      translation_source_slug: post.slug,
      translation_canonical_language: post.language,
      translation_file_path: translation.file_path
    }
  end

  defp build_localized_subtree_variant(post, translation) do
    %{
      post
      | id: translation.id,
        title: translation.title,
        excerpt: translation.excerpt,
        content: translation.content,
        language: translation.language,
        updated_at: translation.updated_at,
        published_at: translation.published_at || post.published_at,
        file_path: translation.file_path
    }
  end

  defp append_generation_index(index, field, key, post) do
    update_in(index[field], fn grouped -> Map.update(grouped, key, [post], &[post | &1]) end)
  end
end
