defmodule BDS.Generation.Outputs do
  @moduledoc false

  import BDS.Generation.Paths
  import BDS.Generation.Renderers
  import BDS.Generation.Sitemap, only: [render_feed: 3, render_atom: 3, render_calendar: 1]

  @spec additional_languages(map()) :: [String.t()]
  def additional_languages(plan) do
    Enum.reject(plan.blog_languages, &(&1 == plan.language))
  end

  @spec route_post_output_path(map(), String.t() | nil) :: String.t()
  def route_post_output_path(post, nil), do: post_output_path(post)
  def route_post_output_path(post, ""), do: post_output_path(post)
  def route_post_output_path(post, route_language), do: post_output_path(post, route_language)

  @spec suppress_subtree_translation_variants([map()], [String.t()]) :: [map()]
  def suppress_subtree_translation_variants(route_posts, additional_languages) do
    subtree_languages = MapSet.new(additional_languages)

    Enum.reject(route_posts, fn post ->
      is_binary(Map.get(post, :translation_source_slug)) and
        MapSet.member?(subtree_languages, to_string(Map.get(post, :language)))
    end)
  end

  @spec build_validation_route_paths(map(), [map()], [map()], map(), String.t() | nil) :: [
          String.t()
        ]
  def build_validation_route_paths(
        plan,
        route_posts,
        published_list_posts,
        post_index,
        route_language
      ) do
    [
      core_route_paths(plan, published_list_posts, route_language),
      page_route_paths(plan, route_posts, route_language),
      single_route_paths(plan, route_posts, route_language),
      category_route_paths(plan, post_index.posts_by_category, route_language),
      tag_route_paths(plan, post_index.posts_by_tag, route_language),
      date_route_paths(plan, post_index, route_language)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec core_route_paths(map(), [map()], String.t() | nil) :: [String.t()]
  def core_route_paths(plan, published_list_posts, route_language) do
    if :core in plan.sections do
      root_route_paths(route_language, length(published_list_posts), plan.max_posts_per_page)
    else
      []
    end
  end

  @spec page_route_paths(map(), [map()], String.t() | nil) :: [String.t()]
  def page_route_paths(plan, route_posts, route_language) do
    if :core in plan.sections do
      route_posts
      |> Enum.filter(&("page" in (&1.categories || [])))
      |> Enum.map(&page_output_path(&1.slug, route_language))
    else
      []
    end
  end

  @spec single_route_paths(map(), [map()], String.t() | nil) :: [String.t()]
  def single_route_paths(plan, route_posts, route_language) do
    if :single in plan.sections do
      Enum.map(route_posts, &route_post_output_path(&1, route_language))
    else
      []
    end
  end

  @spec category_route_paths(map(), map(), String.t() | nil) :: [String.t()]
  def category_route_paths(plan, posts_by_category, route_language) do
    if :category in plan.sections do
      Enum.flat_map(posts_by_category, fn {category, posts} ->
        paginated_archive_paths(
          route_language,
          ["category", archive_route_segment(category)],
          length(posts),
          plan.max_posts_per_page
        )
      end)
    else
      []
    end
  end

  @spec tag_route_paths(map(), map(), String.t() | nil) :: [String.t()]
  def tag_route_paths(plan, posts_by_tag, route_language) do
    if :tag in plan.sections do
      Enum.flat_map(posts_by_tag, fn {tag, posts} ->
        paginated_archive_paths(
          route_language,
          ["tag", archive_route_segment(tag)],
          length(posts),
          plan.max_posts_per_page
        )
      end)
    else
      []
    end
  end

  @spec date_route_paths(map(), map(), String.t() | nil) :: [String.t()]
  def date_route_paths(plan, post_index, route_language) do
    if :date in plan.sections do
      year_paths =
        Enum.flat_map(post_index.posts_by_year, fn {year, posts} ->
          paginated_archive_paths(
            route_language,
            [Integer.to_string(year)],
            length(posts),
            plan.max_posts_per_page
          )
        end)

      month_paths =
        Enum.flat_map(post_index.posts_by_year_month, fn {year_month, posts} ->
          [year, month] = String.split(year_month, "/", parts: 2)

          paginated_archive_paths(
            route_language,
            [year, month],
            length(posts),
            plan.max_posts_per_page
          )
        end)

      day_paths =
        Enum.flat_map(post_index.posts_by_year_month_day, fn {year_month_day, posts} ->
          [year, month, day] = String.split(year_month_day, "/", parts: 3)

          paginated_archive_paths(
            route_language,
            [year, month, day],
            length(posts),
            plan.max_posts_per_page
          )
        end)

      year_paths ++ month_paths ++ day_paths
    else
      []
    end
  end

  @spec build_archive_outputs(map(), map(), map()) :: [{String.t(), iodata()}]
  def build_archive_outputs(plan, post_index, localized_post_indexes) do
    category_outputs =
      if :category in plan.sections do
        build_category_outputs(plan, post_index.posts_by_category, [plan.language]) ++
          Enum.flat_map(additional_languages(plan), fn language ->
            build_category_outputs(
              plan,
              Map.get(localized_post_indexes, language, %{posts_by_category: %{}}).posts_by_category,
              [language]
            )
          end)
      else
        []
      end

    tag_outputs =
      if :tag in plan.sections do
        build_tag_outputs(plan, post_index.posts_by_tag, [plan.language]) ++
          Enum.flat_map(additional_languages(plan), fn language ->
            build_tag_outputs(
              plan,
              Map.get(localized_post_indexes, language, %{posts_by_tag: %{}}).posts_by_tag,
              [language]
            )
          end)
      else
        []
      end

    date_outputs =
      if :date in plan.sections do
        build_date_outputs(plan, post_index, [plan.language]) ++
          Enum.flat_map(additional_languages(plan), fn language ->
            build_date_outputs(
              plan,
              Map.get(
                localized_post_indexes,
                language,
                %{posts_by_year: %{}, posts_by_year_month: %{}, posts_by_year_month_day: %{}}
              ),
              [language]
            )
          end)
      else
        []
      end

    category_outputs ++ tag_outputs ++ date_outputs
  end

  @spec build_category_outputs(map(), map(), [String.t()]) :: [{String.t(), iodata()}]
  def build_category_outputs(plan, posts_by_category, languages) do
    Enum.flat_map(posts_by_category, fn {category, posts} ->
      paginated_posts = Enum.chunk_every(posts, max(plan.max_posts_per_page, 1))
      category_slug = archive_route_segment(category)

      Enum.with_index(paginated_posts, 1)
      |> Enum.flat_map(fn {page_posts, page_number} ->
        Enum.map(languages, fn language ->
          pagination = %{
            current_page: page_number,
            total_pages: length(paginated_posts),
            total_items: length(posts),
            items_per_page: max(plan.max_posts_per_page, 1),
            has_prev_page: page_number > 1,
            prev_page_href:
              if(page_number > 1,
                do:
                  archive_href(
                    route_language(plan.language, language),
                    ["category", category_slug],
                    page_number - 1
                  ),
                else: ""
              ),
            has_next_page: page_number < length(paginated_posts),
            next_page_href:
              if(page_number < length(paginated_posts),
                do:
                  archive_href(
                    route_language(plan.language, language),
                    ["category", category_slug],
                    page_number + 1
                  ),
                else: ""
              )
          }

          {
            archive_path(
              route_language(plan.language, language),
              ["category", category_slug],
              page_number
            ),
            render_archive_page(plan, category, page_posts, language, "category", pagination)
          }
        end)
      end)
    end)
  end

  @spec build_tag_outputs(map(), map(), [String.t()]) :: [{String.t(), iodata()}]
  def build_tag_outputs(plan, posts_by_tag, languages) do
    Enum.flat_map(posts_by_tag, fn {tag, posts} ->
      tag_slug = archive_route_segment(tag)

      build_paginated_archive_outputs(plan, languages, ["tag", tag_slug], posts, fn page_posts,
                                                                                    language,
                                                                                    pagination ->
        render_archive_page(plan, tag, page_posts, language, "tag", pagination)
      end)
    end)
  end

  @spec build_date_outputs(map(), map(), [String.t()]) :: [{String.t(), iodata()}]
  def build_date_outputs(plan, post_index, languages) do
    year_outputs =
      Enum.flat_map(post_index.posts_by_year, fn {year, posts} ->
        build_paginated_archive_outputs(
          plan,
          languages,
          [Integer.to_string(year)],
          posts,
          fn page_posts, language, pagination ->
            render_date_archive_page(
              plan,
              Integer.to_string(year),
              %{kind: "year", year: year},
              page_posts,
              language,
              pagination
            )
          end
        )
      end)

    month_outputs =
      Enum.flat_map(post_index.posts_by_year_month, fn {year_month, posts} ->
        [year, month] = String.split(year_month, "/", parts: 2)

        build_paginated_archive_outputs(plan, languages, [year, month], posts, fn page_posts,
                                                                                  language,
                                                                                  pagination ->
          render_date_archive_page(
            plan,
            "#{year}-#{month}",
            %{kind: "month", year: String.to_integer(year), month: String.to_integer(month)},
            page_posts,
            language,
            pagination
          )
        end)
      end)

    day_outputs =
      Enum.flat_map(post_index.posts_by_year_month_day, fn {year_month_day, posts} ->
        [year, month, day] = String.split(year_month_day, "/", parts: 3)

        build_paginated_archive_outputs(plan, languages, [year, month, day], posts, fn page_posts,
                                                                                       language,
                                                                                       pagination ->
          render_date_archive_page(
            plan,
            "#{year}-#{month}-#{day}",
            %{
              kind: "day",
              year: String.to_integer(year),
              month: String.to_integer(month),
              day: String.to_integer(day)
            },
            page_posts,
            language,
            pagination
          )
        end)
      end)

    year_outputs ++ month_outputs ++ day_outputs
  end

  @spec build_core_outputs(map(), [map()], map()) :: [{String.t(), iodata()}]
  def build_core_outputs(plan, published_posts, localized_posts_by_language) do
    language = plan.language
    additional_languages = Enum.reject(plan.blog_languages, &(&1 == language))
    main_posts = build_list_posts(plan.base_url, published_posts, nil)

    build_root_outputs(plan, language, main_posts) ++
      [
        {"404.html", render_not_found_output(plan, language)},
        {"feed.xml", render_feed(plan, language, published_posts)},
        {"atom.xml", render_atom(plan, language, published_posts)},
        {"calendar.json", render_calendar(published_posts)}
      ] ++
      Enum.flat_map(additional_languages, fn localized_language ->
        localized_prefix = route_language(plan.language, localized_language)
        localized_source_posts = Map.get(localized_posts_by_language, localized_language, [])

        localized_posts =
          build_list_posts(plan.base_url, localized_source_posts, localized_prefix)

        build_root_outputs(plan, localized_language, localized_posts) ++
          [
            {Path.join(localized_language, "404.html"),
             render_not_found_output(plan, localized_language)},
            {Path.join(localized_language, "feed.xml"),
             render_feed(plan, localized_language, localized_source_posts)},
            {Path.join(localized_language, "atom.xml"),
             render_atom(plan, localized_language, localized_source_posts)}
          ]
      end)
  end

  @spec build_page_outputs(String.t(), String.t(), [map()], map(), map()) :: [
          {String.t(), iodata()}
        ]
  def build_page_outputs(
        project_id,
        main_language,
        published_posts,
        translations_by_post_language,
        localized_posts_by_language
      ) do
    page_outputs =
      published_posts
      |> Enum.filter(&("page" in (&1.categories || [])))
      |> Enum.map(fn post ->
        canonical_variant = Map.get(translations_by_post_language, {post.id, main_language}, post)
        body = load_body(project_id, canonical_variant.file_path, canonical_variant.content)

        {page_output_path(post.slug, nil),
         render_post_output(
           project_id,
           post.template_slug,
           %{
             id: canonical_variant.id,
             title: canonical_variant.title,
             content: body,
             slug: post.slug,
             language: canonical_variant.language,
             excerpt: canonical_variant.excerpt
           },
           fn ->
             render_post_page(
               canonical_variant.title,
               body,
               post.slug,
               canonical_variant.language
             )
           end
         )}
      end)

    translation_page_outputs =
      localized_posts_by_language
      |> Enum.flat_map(fn {language, posts} ->
        posts
        |> Enum.filter(&("page" in (&1.categories || [])))
        |> Enum.map(fn post ->
          body = load_body(project_id, post.file_path, post.content)

          {page_output_path(post.slug, language),
           render_post_output(
             project_id,
             post.template_slug,
             %{
               id: post.id,
               title: post.title,
               content: body,
               slug: post.slug,
               language: Map.get(post, :language),
               excerpt: post.excerpt
             },
             fn -> render_post_page(post.title, body, post.slug, Map.get(post, :language)) end
           )}
        end)
      end)

    page_outputs ++ translation_page_outputs
  end

  @spec build_root_outputs(map(), String.t(), [map()]) :: [{String.t(), iodata()}]
  def build_root_outputs(plan, language, posts) do
    total_pages = page_count(length(posts), plan.max_posts_per_page)

    posts
    |> paginate_posts(plan.max_posts_per_page)
    |> Enum.with_index(1)
    |> Enum.map(fn {page_posts, page_number} ->
      route_language = route_language(plan.language, language)

      {root_output_path(route_language, page_number),
       render_list_output(
         plan,
         language,
         plan.project_name,
         page_posts,
         %{kind: "core"},
         pagination_for_page(
           page_number,
           total_pages,
           length(posts),
           plan.max_posts_per_page,
           route_language,
           []
         ),
         fn -> render_home(plan, language) end
       )}
    end)
  end

  @spec build_paginated_archive_outputs(map(), [String.t()], [String.t()], [map()], (... ->
                                                                                       iodata())) ::
          [{String.t(), iodata()}]
  def build_paginated_archive_outputs(plan, languages, segments, posts, render_fun) do
    total_pages = page_count(length(posts), plan.max_posts_per_page)

    posts
    |> paginate_posts(plan.max_posts_per_page)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {page_posts, page_number} ->
      Enum.map(languages, fn language ->
        route_language = route_language(plan.language, language)

        {archive_path(route_language, segments, page_number),
         render_fun.(
           page_posts,
           language,
           pagination_for_page(
             page_number,
             total_pages,
             length(posts),
             plan.max_posts_per_page,
             route_language,
             segments
           )
         )}
      end)
    end)
  end

  @spec build_single_outputs(String.t(), String.t(), [map()], map(), map()) :: [
          {String.t(), iodata()}
        ]
  def build_single_outputs(
        project_id,
        main_language,
        published_posts,
        translations_by_post_language,
        localized_posts_by_language
      ) do
    post_outputs =
      Enum.map(published_posts, fn post ->
        canonical_variant = Map.get(translations_by_post_language, {post.id, main_language}, post)
        body = load_body(project_id, canonical_variant.file_path, canonical_variant.content)

        {post_output_path(post),
         render_post_output(
           project_id,
           post.template_slug,
           %{
             id: canonical_variant.id,
             title: canonical_variant.title,
             content: body,
             slug: post.slug,
             language: canonical_variant.language,
             excerpt: canonical_variant.excerpt
           },
           fn ->
             render_post_page(
               canonical_variant.title,
               body,
               post.slug,
               canonical_variant.language
             )
           end
         )}
      end)

    translation_outputs =
      localized_posts_by_language
      |> Enum.flat_map(fn {language, posts} ->
        Enum.map(posts, fn post ->
          body = load_body(project_id, post.file_path, post.content)

          {post_output_path(post, language),
           render_post_output(
             project_id,
             post.template_slug,
             %{
               id: post.id,
               title: post.title,
               content: body,
               slug: post.slug,
               language: Map.get(post, :language),
               excerpt: post.excerpt
             },
             fn -> render_post_page(post.title, body, post.slug, Map.get(post, :language)) end
           )}
        end)
      end)

    post_outputs ++ translation_outputs
  end
end
