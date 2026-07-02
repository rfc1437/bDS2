defmodule BDS.Generation.Validation do
  @moduledoc false

  import BDS.Generation.Paths,
    only: [
      archive_route_segment: 1,
      local_date_parts!: 1,
      normalize_url_path: 1,
      relative_path_to_url_path: 1,
      url_path_to_relative_index_path: 1
    ]

  import BDS.Generation.Progress, only: [report_validation_compare_progress: 3]
  import BDS.Generation.Sitemap, only: [extract_locs: 1, loc_to_project_path: 2]

  alias BDS.Slug

  # POSIX mtimes from File.stat/2 have second granularity while generation
  # timestamps are milliseconds, so ordering within one second is unknowable;
  # only treat a source file as newer when it is beyond this tolerance.
  @mtime_granularity_tolerance_ms 1_000

  @spec generated_file_updated_at_map([map()]) :: map()
  def generated_file_updated_at_map(generated_files) do
    Map.new(generated_files, &{&1.relative_path, &1.updated_at})
  end

  @spec build_post_timestamp_checks(String.t(), [map()], map()) :: [map()]
  def build_post_timestamp_checks(
        project_data_dir,
        published_route_posts,
        generated_file_updated_at
      ) do
    build_timestamp_checks(
      project_data_dir,
      published_route_posts,
      generated_file_updated_at,
      &BDS.Generation.Paths.post_output_path/1,
      fn post -> Map.get(post, :translation_file_path) || post.file_path end
    )
  end

  @spec build_language_post_timestamp_checks(String.t(), String.t(), [map()], map()) :: [map()]
  def build_language_post_timestamp_checks(
        project_data_dir,
        language,
        published_posts,
        generated_file_updated_at
      ) do
    build_timestamp_checks(
      project_data_dir,
      published_posts,
      generated_file_updated_at,
      fn post -> BDS.Generation.Paths.post_output_path(post, language) end,
      & &1.file_path
    )
  end

  defp build_timestamp_checks(
         project_data_dir,
         posts,
         generated_file_updated_at,
         relative_path_fun,
         source_file_fun
       ) do
    Enum.map(posts, fn post ->
      relative_path = relative_path_fun.(post)

      %{
        post_url_path: relative_path_to_url_path(relative_path),
        post_file_path: source_full_path(project_data_dir, source_file_fun.(post)),
        generated_updated_at_ms: Map.get(generated_file_updated_at, relative_path, 0)
      }
    end)
  end

  defp source_full_path(_project_data_dir, file_path) when file_path in [nil, ""], do: nil
  defp source_full_path(project_data_dir, file_path), do: Path.join(project_data_dir, file_path)

  @spec compare_sitemap_to_html(map()) :: map()
  def compare_sitemap_to_html(params) do
    post_timestamp_checks = Map.get(params, :post_timestamp_checks, [])
    index_paths = Path.wildcard(Path.join(params.html_dir, "**/index.html"))
    total_compare_steps = max(length(index_paths) + length(post_timestamp_checks), 1)

    expected_path_set =
      params.sitemap_xml
      |> extract_locs()
      |> Enum.map(&loc_to_project_path(&1, params.base_url))
      |> Enum.reduce(MapSet.new(), &MapSet.put(&2, normalize_url_path(&1)))
      |> then(fn expected_paths ->
        Enum.reduce(Map.get(params, :additional_expected_paths, []), expected_paths, fn path,
                                                                                        acc ->
          MapSet.put(acc, normalize_url_path(path))
        end)
      end)

    {existing_html_path_set, zero_byte_html_path_set} =
      collect_html_index_paths(
        index_paths,
        params.html_dir,
        params.on_progress,
        total_compare_steps
      )

    missing_url_paths =
      expected_path_set
      |> MapSet.to_list()
      |> Enum.reject(&MapSet.member?(existing_html_path_set, &1))
      |> Enum.sort()

    extra_url_paths =
      existing_html_path_set
      |> MapSet.to_list()
      |> Enum.reject(&MapSet.member?(expected_path_set, &1))
      |> Kernel.++(
        zero_byte_html_path_set
        |> MapSet.to_list()
        |> Enum.reject(&MapSet.member?(expected_path_set, &1))
      )
      |> Enum.uniq()
      |> Enum.sort()

    updated_post_url_paths =
      post_timestamp_checks
      |> Enum.with_index(1)
      |> Enum.reduce(MapSet.new(), fn {check, index}, acc ->
        :ok =
          report_validation_compare_progress(
            params.on_progress,
            length(index_paths) + index,
            total_compare_steps
          )

        normalized_url_path = normalize_url_path(check.post_url_path)

        cond do
          not MapSet.member?(expected_path_set, normalized_url_path) ->
            acc

          normalized_url_path in missing_url_paths ->
            acc

          is_nil(check.post_file_path) or check.post_file_path == "" ->
            acc

          true ->
            html_path =
              Path.join(params.html_dir, url_path_to_relative_index_path(normalized_url_path))

            case {File.stat(html_path, time: :posix),
                  File.stat(check.post_file_path, time: :posix)} do
              {{:ok, html_stat}, {:ok, post_stat}} ->
                effective_generated_at_ms =
                  max(mtime_ms(html_stat), check.generated_updated_at_ms || 0)

                if mtime_ms(post_stat) >
                     effective_generated_at_ms + @mtime_granularity_tolerance_ms do
                  MapSet.put(acc, normalized_url_path)
                else
                  acc
                end

              _other ->
                acc
            end
        end
      end)
      |> MapSet.to_list()
      |> Enum.sort()

    %{
      missing_url_paths: missing_url_paths,
      extra_url_paths: extra_url_paths,
      updated_post_url_paths: updated_post_url_paths,
      expected_url_count: MapSet.size(expected_path_set),
      existing_html_url_count: MapSet.size(existing_html_path_set)
    }
  end

  defp collect_html_index_paths(index_paths, html_dir, on_progress, total_compare_steps) do
    index_paths
    |> Enum.with_index(1)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn {path, index}, {existing, zero_byte} ->
      :ok = report_validation_compare_progress(on_progress, index, total_compare_steps)

      relative_dir =
        path
        |> Path.relative_to(html_dir)
        |> Path.dirname()

      url_path =
        case relative_dir do
          "." -> "/"
          value -> normalize_url_path("/" <> value)
        end

      case File.stat(path) do
        {:ok, %{size: size}} when size > 0 -> {MapSet.put(existing, url_path), zero_byte}
        {:ok, _stat} -> {existing, MapSet.put(zero_byte, url_path)}
        {:error, _reason} -> {existing, MapSet.put(zero_byte, url_path)}
      end
    end)
  end

  defp mtime_ms(%{mtime: mtime}) when is_integer(mtime), do: mtime * 1000

  defp mtime_ms(%{mtime: mtime}) do
    mtime
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  @spec report_paths(map()) :: [String.t()]
  def report_paths(report) do
    Map.get(report, :missing_url_paths, []) ++ Map.get(report, :updated_post_url_paths, [])
  end

  @spec plan_validation_paths([String.t()], [String.t()]) :: map()
  def plan_validation_paths(paths, additional_languages) do
    {main_plan, language_plans} =
      Enum.reduce(paths, {empty_validation_path_plan(), %{}}, fn path, {plan, language_plans} ->
        normalized_path = normalize_url_path(path)
        {language, stripped_path} = extract_language_path(normalized_path, additional_languages)

        if is_binary(language) do
          language_plan = Map.get(language_plans, language, empty_validation_path_plan())
          next_language_plan = classify_validation_path(stripped_path, language_plan)
          {plan, Map.put(language_plans, language, next_language_plan)}
        else
          {classify_validation_path(normalized_path, plan), language_plans}
        end
      end)

    Map.put(main_plan, :language_plans, language_plans)
  end

  @spec empty_validation_path_plan() :: map()
  def empty_validation_path_plan do
    %{
      request_root_routes: false,
      requires_fallback_section_render: false,
      requested_category_slugs: MapSet.new(),
      requested_tag_slugs: MapSet.new(),
      requested_years: MapSet.new(),
      requested_year_months: MapSet.new(),
      requested_year_month_days: MapSet.new(),
      requested_post_routes: [],
      requested_page_slugs: MapSet.new(),
      language_plans: %{}
    }
  end

  defp classify_validation_path(path, plan) do
    case Regex.run(~r|^/category/([^/]+)(?:/page/\d+)?$|, path) do
      [_, slug] ->
        update_in(plan.requested_category_slugs, &MapSet.put(&1, slug))

      nil ->
        case Regex.run(~r|^/tag/([^/]+)(?:/page/\d+)?$|, path) do
          [_, slug] ->
            update_in(plan.requested_tag_slugs, &MapSet.put(&1, slug))

          nil ->
            case Regex.run(~r|^/(\d{4})/(\d{2})/(\d{2})/([^/]+)$|, path) do
              [_, year, month, day, slug] ->
                update_in(
                  plan.requested_post_routes,
                  &[
                    %{
                      year: String.to_integer(year),
                      month: String.to_integer(month),
                      day: String.to_integer(day),
                      slug: slug
                    }
                    | &1
                  ]
                )

              nil ->
                classify_archive_or_page_validation_path(path, plan)
            end
        end
    end
  end

  defp classify_archive_or_page_validation_path(path, plan) do
    cond do
      Regex.match?(~r|^/(\d{4})/(\d{2})/(\d{2})(?:/page/\d+)?$|, path) ->
        [_, year, month, day] = Regex.run(~r|^/(\d{4})/(\d{2})/(\d{2})(?:/page/\d+)?$|, path)
        update_in(plan.requested_year_month_days, &MapSet.put(&1, "#{year}/#{month}/#{day}"))

      Regex.match?(~r|^/(\d{4})/(\d{2})(?:/page/\d+)?$|, path) ->
        [_, year, month] = Regex.run(~r|^/(\d{4})/(\d{2})(?:/page/\d+)?$|, path)
        update_in(plan.requested_year_months, &MapSet.put(&1, "#{year}/#{month}"))

      Regex.match?(~r|^/(\d{4})(?:/page/\d+)?$|, path) ->
        [_, year] = Regex.run(~r|^/(\d{4})(?:/page/\d+)?$|, path)
        update_in(plan.requested_years, &MapSet.put(&1, String.to_integer(year)))

      path == "/" or Regex.match?(~r|^/page/\d+$|, path) ->
        %{plan | request_root_routes: true}

      Regex.match?(~r|^/([^/]+)$|, path) ->
        [_, slug] = Regex.run(~r|^/([^/]+)$|, path)
        update_in(plan.requested_page_slugs, &MapSet.put(&1, slug))

      true ->
        %{plan | requires_fallback_section_render: true}
    end
  end

  @spec build_targeted_validation_plan(map(), [map()]) :: map()
  def build_targeted_validation_plan(initial_plan, published_posts) do
    if initial_plan.requires_fallback_section_render do
      initial_plan
    else
      available_category_slugs =
        published_posts
        |> Enum.flat_map(&(&1.categories || []))
        |> Enum.map(&Slug.slugify/1)
        |> MapSet.new()

      available_tag_slugs =
        published_posts
        |> Enum.flat_map(&(&1.tags || []))
        |> Enum.map(&Slug.slugify/1)
        |> MapSet.new()

      targeted_post_routes =
        Enum.reduce(initial_plan.requested_post_routes, MapSet.new(), fn route, acc ->
          MapSet.put(acc, route_key(route.year, route.month, route.day, route.slug))
        end)

      enriched =
        Enum.reduce(
          initial_plan.requested_post_routes,
          %{initial_plan | requested_post_routes: targeted_post_routes},
          fn route, acc ->
            case Enum.find(published_posts, &post_matches_route?(&1, route)) do
              nil ->
                acc
                |> update_in([:requested_years], &MapSet.put(&1, route.year))
                |> update_in(
                  [:requested_year_months],
                  &MapSet.put(&1, route_month_key(route.year, route.month))
                )
                |> update_in(
                  [:requested_year_month_days],
                  &MapSet.put(&1, route_day_key(route.year, route.month, route.day))
                )
                |> Map.put(:request_root_routes, true)

              post ->
                {year, month, day} = local_date_parts!(post.created_at)

                acc
                |> update_in([:requested_category_slugs], fn set ->
                  Enum.reduce(
                    post.categories || [],
                    set,
                    &MapSet.put(&2, archive_route_segment(&1))
                  )
                end)
                |> update_in([:requested_tag_slugs], fn set ->
                  Enum.reduce(post.tags || [], set, &MapSet.put(&2, archive_route_segment(&1)))
                end)
                |> update_in([:requested_years], &MapSet.put(&1, year))
                |> update_in(
                  [:requested_year_months],
                  &MapSet.put(&1, route_month_key(year, month))
                )
                |> update_in(
                  [:requested_year_month_days],
                  &MapSet.put(&1, route_day_key(year, month, day))
                )
                |> Map.put(:request_root_routes, true)
            end
          end
        )
        |> cascade_requested_date_archives()

      language_plans =
        initial_plan.language_plans
        |> Enum.map(fn {language, language_plan} ->
          {language, build_targeted_validation_plan(language_plan, published_posts)}
        end)
        |> Map.new()

      %{
        enriched
        | requested_category_slugs:
            MapSet.intersection(enriched.requested_category_slugs, available_category_slugs),
          requested_tag_slugs:
            MapSet.intersection(enriched.requested_tag_slugs, available_tag_slugs),
          language_plans: language_plans
      }
    end
  end

  defp post_matches_route?(post, route) do
    {year, month, day} = local_date_parts!(post.created_at)

    post.slug == route.slug and year == route.year and month == route.month and day == route.day
  end

  @spec route_key(integer(), integer(), integer(), String.t()) :: String.t()
  def route_key(year, month, day, slug) do
    "#{year}/#{String.pad_leading(Integer.to_string(month), 2, "0")}/#{String.pad_leading(Integer.to_string(day), 2, "0")}/#{slug}"
  end

  defp route_month_key(year, month) do
    "#{year}/#{String.pad_leading(Integer.to_string(month), 2, "0")}"
  end

  defp route_day_key(year, month, day) do
    "#{route_month_key(year, month)}/#{String.pad_leading(Integer.to_string(day), 2, "0")}"
  end

  defp cascade_requested_date_archives(plan) do
    plan
    |> cascade_requested_year_month_days()
    |> cascade_requested_year_months()
  end

  defp cascade_requested_year_month_days(plan) do
    Enum.reduce(plan.requested_year_month_days, plan, fn year_month_day, acc ->
      [year, month, _day] = String.split(year_month_day, "/", parts: 3)

      acc
      |> update_in([:requested_year_months], &MapSet.put(&1, "#{year}/#{month}"))
      |> update_in([:requested_years], &MapSet.put(&1, String.to_integer(year)))
    end)
  end

  defp cascade_requested_year_months(plan) do
    Enum.reduce(plan.requested_year_months, plan, fn year_month, acc ->
      [year | _rest] = String.split(year_month, "/", parts: 2)
      update_in(acc.requested_years, &MapSet.put(&1, String.to_integer(year)))
    end)
  end

  defp extract_language_path(path, additional_languages) do
    case Regex.run(~r|^/([a-z]{2,3})(/.*)?$|, path) do
      [_, language, suffix] ->
        if language in additional_languages do
          {language, normalize_url_path(suffix)}
        else
          {nil, path}
        end

      [_, language] ->
        if language in additional_languages do
          {language, "/"}
        else
          {nil, path}
        end

      _other ->
        {nil, path}
    end
  end

  @spec route_html_path?(String.t()) :: boolean()
  def route_html_path?(relative_path), do: String.ends_with?(relative_path, "index.html")

  @spec prune_empty_parent_dirs(String.t(), String.t()) :: {non_neg_integer(), String.t()}
  def prune_empty_parent_dirs(current_dir, html_root) do
    cond do
      Path.expand(current_dir) == Path.expand(html_root) ->
        {0, current_dir}

      true ->
        case File.ls(current_dir) do
          {:ok, []} ->
            case File.rmdir(current_dir) do
              :ok ->
                {count, last_dir} = prune_empty_parent_dirs(Path.dirname(current_dir), html_root)
                {count + 1, last_dir}

              {:error, _reason} ->
                {0, current_dir}
            end

          _other ->
            {0, current_dir}
        end
    end
  end
end
