defmodule BDS.Generation do
  @moduledoc """
  Context for static-site generation: plan, generate, and validate a project's
  rendered output, apply validation results, and write generated files.

  Generation is organised into sections (defaulting to `:core`) so callers can
  regenerate a subset of the site.
  """

  import Ecto.Query

  import BDS.Generation.Paths,
    except: [post_output_path: 1, post_output_path: 2]

  import BDS.Generation.Sitemap,
    only: [
      render: 1,
      render_multi_language: 6
    ]

  import BDS.Generation.Progress
  import BDS.Generation.Outputs
  import BDS.Generation.Data
  import BDS.Generation.Renderers, only: [build_list_posts: 3]
  import BDS.Generation.Validation

  alias BDS.Generation.GeneratedFileHash
  alias BDS.Generation.Paths
  alias BDS.Metadata
  alias BDS.Persistence
  alias BDS.PreviewAssets
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  @core_sections [:core, :single, :category, :tag, :date]

  @typedoc "A section identifier accepted by `generate_site/3` and friends."
  @type section :: :core | :single | :category | :tag | :date

  @typedoc "Options accepted by long-running generation operations."
  @type generation_opts :: keyword()

  @typedoc "Plan returned by `plan_generation/2`."
  @type plan :: map()

  @typedoc "Validation report returned by `validate_site/3`."
  @type validation_report :: map()

  @spec plan_generation(String.t(), [section()]) :: {:ok, plan()}
  def plan_generation(project_id, sections \\ [:core])
      when is_binary(project_id) and is_list(sections) do
    project = Projects.get_project!(project_id)
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    {:ok, generated_files} = list_generated_files(project_id)

    {:ok,
     %{
       project_id: project_id,
       project_name: project.name,
       base_url: normalize_base_url(metadata.public_url),
       language: metadata.main_language,
       blog_languages: normalize_blog_languages(metadata.main_language, metadata.blog_languages),
       max_posts_per_page: metadata.max_posts_per_page,
       categories: metadata.categories,
       category_settings: metadata.category_settings,
       pico_theme: metadata.pico_theme,
       sections: normalize_sections(sections),
       generated_files: generated_files
     }}
  end

  @spec generate_site(String.t(), [section()], generation_opts()) ::
          {:ok, %{sections: [section()], generated_files: [map()]}} | {:error, term()}
  def generate_site(project_id, sections \\ [:core], opts \\ [])

  def generate_site(project_id, sections, opts)
      when is_binary(project_id) and is_list(sections) and is_list(opts) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      outputs = build_outputs(plan)
      on_progress = callback(opts)
      total_outputs = length(outputs)

      :ok = report_generation_started(on_progress, total_outputs, "generated files")

      outputs
      |> Enum.with_index(1)
      |> Enum.each(fn {{relative_path, content}, index} ->
        {:ok, _write} = write_generated_file(project_id, relative_path, content)
        :ok = report_generation_progress(on_progress, index, total_outputs, "generated files")
      end)

      {:ok, generated_files} = list_generated_files(project_id)
      {:ok, %{sections: plan.sections, generated_files: generated_files}}
    end
  end

  @spec validate_site(String.t(), [section()], generation_opts()) ::
          {:ok, validation_report()} | {:error, term()}
  def validate_site(project_id, sections \\ @core_sections, opts \\ [])

  def validate_site(project_id, sections, opts)
      when is_binary(project_id) and is_list(sections) and is_list(opts) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      on_progress = callback(opts)
      :ok = report_validation_progress(on_progress, 0.0, "Collecting sitemap URLs...")

      data =
        generation_data(plan,
          on_snapshot_progress: fn stage, current, total ->
            report_validation_snapshot_progress(on_progress, stage, current, total)
          end
        )

      {:ok, generated_files_list} = list_generated_files(project_id)
      generated_file_updated_at = generated_file_updated_at_map(generated_files_list)
      additional_languages = additional_languages(plan)

      published_route_posts =
        suppress_subtree_translation_variants(data.published_route_posts, additional_languages)

      {sitemap_content, sitemap_to_write, additional_expected_paths,
       additional_post_timestamp_checks} =
        build_validation_sitemap_artifacts(
          plan,
          data,
          published_route_posts,
          generated_file_updated_at,
          on_progress
        )

      {:ok, sitemap_write} =
        write_generated_file(project_id, "sitemap.xml", sitemap_to_write)

      :ok = report_validation_progress(on_progress, 0.5, "Comparing sitemap to html pages...")

      diff_result =
        compare_sitemap_to_html(%{
          sitemap_xml: sitemap_content,
          base_url: plan.base_url,
          html_dir: output_path(data.project, ""),
          on_progress: on_progress,
          post_timestamp_checks:
            build_post_timestamp_checks(
              data.project_data_dir,
              published_route_posts,
              generated_file_updated_at
            ) ++ additional_post_timestamp_checks,
          additional_expected_paths: additional_expected_paths
        })

      completion_message =
        "Validation complete (#{length(diff_result.missing_url_paths)} missing, #{length(diff_result.extra_url_paths)} extra, #{length(diff_result.updated_post_url_paths)} updated)"

      :ok = report_validation_progress(on_progress, 1.0, completion_message)

      {:ok,
       %{
         sitemap_path: output_path(data.project, "sitemap.xml"),
         sitemap_changed: sitemap_write.written?,
         missing_url_paths: diff_result.missing_url_paths,
         extra_url_paths: diff_result.extra_url_paths,
         updated_post_url_paths: diff_result.updated_post_url_paths,
         expected_url_count: diff_result.expected_url_count,
         existing_html_url_count: diff_result.existing_html_url_count
       }}
    end
  end

  @spec apply_validation(String.t(), [section()] | map()) :: {:ok, map()} | {:error, term()}
  def apply_validation(project_id, sections) when is_binary(project_id) and is_list(sections) do
    with {:ok, plan} <- plan_generation(project_id, sections),
         {:ok, actual_files} <- disk_generated_files(project_id) do
      expected_outputs = build_outputs(plan)
      expected_paths = MapSet.new(Enum.map(expected_outputs, &elem(&1, 0)))
      project = Projects.get_project!(project_id)
      now = Persistence.now_ms()

      Enum.each(expected_outputs, fn {relative_path, content} ->
        expected_hash = sha256(content)

        case actual_files do
          %{^relative_path => ^expected_hash} ->
            :ok

          _other ->
            :ok = Persistence.atomic_write(output_path(project, relative_path), content)

            %GeneratedFileHash{}
            |> GeneratedFileHash.changeset(%{
              project_id: project_id,
              relative_path: relative_path,
              content_hash: expected_hash,
              updated_at: now
            })
            |> Repo.insert!(
              on_conflict: [set: [content_hash: expected_hash, updated_at: now]],
              conflict_target: [:project_id, :relative_path]
            )
        end
      end)

      with {:ok, generated_files_on_disk} <- disk_generated_files(project_id) do
        generated_files_on_disk
        |> Map.keys()
        |> Enum.filter(fn relative_path ->
          path_section(relative_path) in plan.sections and
            not MapSet.member?(expected_paths, relative_path)
        end)
        |> Enum.each(fn relative_path ->
          _ = File.rm(output_path(project, relative_path))

          Repo.delete_all(
            from generated_file in GeneratedFileHash,
              where:
                generated_file.project_id == ^project_id and
                  generated_file.relative_path == ^relative_path
          )
        end)

        {:ok, generated_files} = list_generated_files(project_id)
        {:ok, %{sections: plan.sections, generated_files: generated_files}}
      end
    end
  end

  def apply_validation(project_id, report) when is_binary(project_id) and is_map(report) do
    apply_validation(project_id, report, [])
  end

  @spec prepare_validation_apply(String.t(), map(), generation_opts()) ::
          {:ok, map()} | {:error, term()}
  def prepare_validation_apply(project_id, report, opts \\ [])

  def prepare_validation_apply(project_id, report, opts)
      when is_binary(project_id) and is_map(report) and is_list(opts) do
    on_progress = callback(opts)
    :ok = report_validation_progress(on_progress, 0.0, "Planning validation apply steps...")

    with {:ok, apply_plan} <- validation_apply_plan(project_id, @core_sections, report) do
      sections_to_render = validation_apply_sections_to_render(apply_plan.targeted_plan)
      project = Projects.get_project!(project_id)

      :ok = report_validation_progress(on_progress, 0.2, "Deleting extra URLs...")

      {deleted_url_count, removed_empty_dir_count} =
        delete_extra_validation_paths(
          project_id,
          project,
          Map.get(report, :extra_url_paths, []),
          on_progress
        )

      :ok =
        report_validation_progress(
          on_progress,
          1.0,
          "Validation apply prepared"
        )

      {:ok,
       %{
         sections_to_render: sections_to_render,
         deleted_url_count: deleted_url_count,
         removed_empty_dir_count: removed_empty_dir_count
       }}
    end
  end

  @spec apply_validation_section(String.t(), map(), section(), generation_opts()) ::
          {:ok, map()} | {:error, term()}
  def apply_validation_section(project_id, report, section, opts \\ [])

  def apply_validation_section(project_id, report, section, opts)
      when is_binary(project_id) and is_map(report) and section in @core_sections and
             is_list(opts) do
    on_progress = callback(opts)
    :ok = report_validation_progress(on_progress, 0.0, validation_section_task_label(section))

    with {:ok, apply_plan} <- validation_apply_plan(project_id, [section], report) do
      outputs_to_render =
        targeted_apply_outputs(apply_plan.plan, apply_plan.targeted_plan, [section])

      rendered_url_count = write_validation_outputs(project_id, outputs_to_render, on_progress)

      {:ok, %{section: section, rendered_url_count: rendered_url_count}}
    end
  end

  @spec refresh_validation_ancillary_outputs(String.t(), :calendar, generation_opts()) ::
          {:ok, map()} | {:error, term()}
  def refresh_validation_ancillary_outputs(project_id, kind, opts \\ [])

  def refresh_validation_ancillary_outputs(project_id, kind, opts)
      when is_binary(project_id) and kind in [:calendar] and is_list(opts) do
    on_progress = callback(opts)
    :ok = report_validation_progress(on_progress, 0.0, ancillary_validation_task_label(kind))

    with {:ok, plan} <- plan_generation(project_id, @core_sections) do
      expected_output_map = refresh_validation_output_map(plan, kind, on_progress)
      paths = ancillary_validation_paths(expected_output_map, kind)
      label = ancillary_validation_progress_label(kind)
      total = length(paths)

      :ok = report_generation_started(on_progress, total, label)

      paths
      |> Enum.with_index(1)
      |> Enum.each(fn {relative_path, index} ->
        _ =
          write_generated_file(
            project_id,
            relative_path,
            Map.fetch!(expected_output_map, relative_path)
          )

        :ok = report_generation_progress(on_progress, index, total, label)
      end)

      {:ok, %{kind: kind, written_count: length(paths)}}
    end
  end

  defp refresh_validation_output_map(plan, :calendar, _on_progress) do
    data = generation_data(plan)
    %{"calendar.json" => BDS.Generation.Sitemap.render_calendar(data.published_list_posts)}
  end

  @spec apply_validation(String.t(), map(), generation_opts()) :: {:ok, map()} | {:error, term()}
  def apply_validation(project_id, report, opts)
      when is_binary(project_id) and is_map(report) and is_list(opts) do
    on_progress = callback(opts)

    with {:ok, apply_plan} <- validation_apply_plan(project_id, @core_sections, report) do
      plan = apply_plan.plan
      project = Projects.get_project!(project_id)

      outputs_to_render = targeted_apply_outputs(plan, apply_plan.targeted_plan, plan.sections)

      rendered_url_count = write_validation_outputs(project_id, outputs_to_render, on_progress)

      {deleted_url_count, removed_empty_dir_count} =
        delete_extra_validation_paths(project_id, project, Map.get(report, :extra_url_paths, []))

      if outputs_to_render != [] or deleted_url_count > 0 do
        {:ok, _} = refresh_validation_ancillary_outputs(project_id, :calendar)
      end

      {:ok,
       %{
         rendered_url_count: rendered_url_count,
         deleted_url_count: deleted_url_count,
         removed_empty_dir_count: removed_empty_dir_count
       }}
    end
  end

  @spec post_output_path(map()) :: String.t()
  defdelegate post_output_path(post), to: Paths

  @spec post_output_path(map(), String.t() | nil) :: String.t()
  defdelegate post_output_path(post, language), to: Paths

  @typedoc "Result returned by `write_generated_file/3,4`."
  @type write_result :: %{
          relative_path: String.t(),
          content_hash: String.t(),
          written?: boolean()
        }

  @spec write_generated_file(String.t(), String.t(), String.t()) :: {:ok, write_result()}
  def write_generated_file(project_id, relative_path, content),
    do: write_generated_file(project_id, relative_path, content, [])

  @spec write_generated_file(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, write_result()}
  def write_generated_file(project_id, relative_path, content, opts)
      when is_binary(project_id) and is_binary(relative_path) and is_binary(content) and
             is_list(opts) do
    project = Projects.get_project!(project_id)
    content_hash = sha256(content)
    now = Persistence.now_ms()
    full_path = output_path(project, relative_path)
    refresh_timestamp? = Keyword.get(opts, :refresh_timestamp_on_unchanged, false)

    case Repo.get_by(GeneratedFileHash, project_id: project_id, relative_path: relative_path) do
      %GeneratedFileHash{content_hash: ^content_hash} ->
        cond do
          not File.exists?(full_path) ->
            :ok = Persistence.atomic_write(full_path, content)
            :ok = upsert_generated_file_hash(project_id, relative_path, content_hash, now)
            {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: true}}

          refresh_timestamp? ->
            :ok = upsert_generated_file_hash(project_id, relative_path, content_hash, now)
            {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: false}}

          true ->
            {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: false}}
        end

      _existing ->
        :ok = Persistence.atomic_write(full_path, content)
        :ok = upsert_generated_file_hash(project_id, relative_path, content_hash, now)

        {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: true}}
    end
  end

  @spec list_generated_files(String.t()) :: {:ok, [map()]}
  def list_generated_files(project_id) when is_binary(project_id) do
    {:ok,
     Repo.all(
       from generated_file in GeneratedFileHash,
         where: generated_file.project_id == ^project_id,
         order_by: [asc: generated_file.relative_path]
     )}
  end

  @spec delete_generated_file(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_generated_file(project_id, relative_path)
      when is_binary(project_id) and is_binary(relative_path) do
    project = Projects.get_project!(project_id)

    case File.rm(output_path(project, relative_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end

    Repo.delete_all(
      from generated_file in GeneratedFileHash,
        where:
          generated_file.project_id == ^project_id and
            generated_file.relative_path == ^relative_path
    )

    :ok
  end

  defp build_outputs(plan, on_output \\ nil) do
    data = generation_data(plan)
    published_translations = flattened_generation_translations(data.translations_by_post)
    translations_by_post_language = translation_lookup_map(published_translations)

    translatable_published_posts =
      Enum.reject(data.published_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

    translatable_published_list_posts =
      Enum.reject(data.published_list_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

    localized_posts_by_language =
      additional_languages(plan)
      |> Enum.map(fn language ->
        {language,
         resolve_posts_for_language(
           translatable_published_posts,
           language,
           translations_by_post_language,
           plan.language
         )}
      end)
      |> Map.new()

    localized_list_posts_by_language =
      additional_languages(plan)
      |> Enum.map(fn language ->
        {language,
         resolve_posts_for_language(
           translatable_published_list_posts,
           language,
           translations_by_post_language,
           plan.language
         )}
      end)
      |> Map.new()

    localized_post_indexes =
      localized_list_posts_by_language
      |> Enum.map(fn {language, posts} -> {language, build_generation_post_index(posts)} end)
      |> Map.new()

    core_outputs =
      if :core in plan.sections do
        build_core_outputs(
          plan,
          data.published_list_posts,
          localized_list_posts_by_language,
          on_output
        )
      else
        []
      end

    page_outputs =
      if :core in plan.sections do
        build_page_outputs(
          plan.project_id,
          plan.language,
          data.published_posts,
          translations_by_post_language,
          localized_posts_by_language,
          on_output
        )
      else
        []
      end

    single_outputs =
      if :single in plan.sections do
        build_single_outputs(
          plan.project_id,
          plan.language,
          data.published_posts,
          translations_by_post_language,
          localized_posts_by_language,
          on_output
        )
      else
        []
      end

    archive_outputs =
      build_archive_outputs(plan, data.post_index, localized_post_indexes, on_output)

    urls =
      (core_outputs ++ page_outputs ++ single_outputs ++ archive_outputs)
      |> Enum.filter(fn {relative_path, _content} -> sitemap_route_output?(relative_path) end)
      |> Enum.map(fn {relative_path, _content} ->
        url_for_output(plan.base_url, relative_path)
      end)

    sitemap =
      if :core in plan.sections do
        [{"sitemap.xml", render(urls)}]
      else
        []
      end

    pagefind_outputs =
      if :core in plan.sections do
        BDS.Generation.Pagefind.build_outputs(
          plan,
          core_outputs ++ page_outputs ++ single_outputs ++ archive_outputs
        )
      else
        []
      end

    asset_outputs =
      if :core in plan.sections do
        PreviewAssets.generated_outputs()
      else
        []
      end

    core_outputs ++
      page_outputs ++
      single_outputs ++ archive_outputs ++ sitemap ++ pagefind_outputs ++ asset_outputs
  end

  defp build_validation_sitemap_artifacts(
         plan,
         data,
         published_route_posts,
         generated_file_updated_at,
         on_progress
       ) do
    main_paths =
      build_validation_route_paths(
        plan,
        published_route_posts,
        data.published_list_posts,
        data.post_index,
        nil
      )

    additional_language_sets =
      Enum.map(additional_languages(plan), fn language ->
        language_posts =
          Enum.reject(data.published_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

        language_list_posts =
          Enum.reject(data.published_list_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

        language_post_index = build_generation_post_index(language_list_posts)

        {language, language_posts,
         build_validation_route_paths(
           plan,
           language_posts,
           language_list_posts,
           language_post_index,
           language
         )}
      end)

    all_collection_paths =
      main_paths ++
        Enum.flat_map(additional_language_sets, fn {_language, _posts, paths} -> paths end)

    total_route_count = max(length(all_collection_paths), 1)

    all_collection_paths
    |> Enum.with_index(1)
    |> Enum.each(fn {_relative_path, index} ->
      :ok = report_validation_collection_progress(on_progress, index, total_route_count)
    end)

    sitemap_content =
      main_paths
      |> Enum.map(&url_for_output(plan.base_url, &1))
      |> render()

    additional_expected_paths =
      additional_language_sets
      |> Enum.flat_map(fn {_language, _posts, paths} -> paths end)
      |> Enum.map(&relative_path_to_url_path/1)

    additional_post_timestamp_checks =
      additional_language_sets
      |> Enum.flat_map(fn {language, posts, _paths} ->
        build_language_post_timestamp_checks(
          data.project_data_dir,
          language,
          posts,
          generated_file_updated_at
        )
      end)

    sitemap_to_write =
      case additional_languages(plan) do
        [] ->
          sitemap_content

        languages ->
          render_multi_language(
            plan,
            Enum.reject(data.published_posts, &truthy_flag?(Map.get(&1, :do_not_translate))),
            Enum.filter(data.published_posts, &truthy_flag?(Map.get(&1, :do_not_translate))),
            data.published_list_posts,
            data.post_index,
            languages
          )
      end

    {sitemap_content, sitemap_to_write, additional_expected_paths,
     additional_post_timestamp_checks}
  end

  defp disk_generated_files(project_id) do
    project = Projects.get_project!(project_id)
    html_root = output_path(project, "")

    case File.ls(html_root) do
      {:ok, _entries} ->
        html_root
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, files} ->
          relative_path = Path.relative_to(path, html_root)

          case File.read(path) do
            {:ok, contents} ->
              {:cont, {:ok, Map.put(files, relative_path, sha256(contents))}}

            {:error, reason} ->
              {:halt, {:error, {:read_generated_file, path, reason}}}
          end
        end)

      {:error, :enoent} ->
        {:ok, %{}}
    end
  end

  defp validation_apply_plan(project_id, sections, report) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      published_posts = list_published_posts(project_id)

      targeted_plan =
        build_targeted_validation_plan(
          plan_validation_paths(report_paths(report), additional_languages(plan)),
          published_posts
        )

      {:ok, %{plan: plan, targeted_plan: targeted_plan}}
    end
  end

  # Render ONLY the routes targeted by the validation report for the given
  # sections, matching the old app's behaviour of filtering the render inputs
  # rather than rendering the whole site and discarding the surplus. Falls back
  # to a full section render only when a report path could not be classified.
  defp targeted_apply_outputs(plan, targeted_plan, sections) do
    if fallback_validation_section_render?(targeted_plan) do
      Enum.filter(build_outputs(plan), fn {relative_path, _content} ->
        path_section(relative_path) in sections
      end)
    else
      render_data = validation_render_data(plan)

      Enum.flat_map(sections, fn section ->
        build_targeted_section_outputs(plan, render_data, targeted_plan, section)
      end)
    end
  end

  # Write the targeted outputs, streaming one progress message per rewritten URL
  # (exactly like the old app's `Generated /url` reporting) so the task shows the
  # actual URLs and advances by the number of URLs rewritten.
  defp write_validation_outputs(project_id, outputs, on_progress) do
    route_total = Enum.count(outputs, fn {relative_path, _content} -> route_html_path?(relative_path) end)

    :ok = report_validation_progress(on_progress, 0.0, validation_rewrite_started_message(route_total))

    {rendered, _total} =
      Enum.reduce(outputs, {0, route_total}, fn {relative_path, content}, {rendered, total} ->
        _ =
          write_generated_file(project_id, relative_path, content,
            refresh_timestamp_on_unchanged: route_html_path?(relative_path)
          )

        if route_html_path?(relative_path) do
          rewritten = rendered + 1
          progress = if total > 0, do: rewritten / total, else: 1.0

          :ok =
            report_validation_progress(
              on_progress,
              progress,
              "Rewrote #{relative_path_to_url_path(relative_path)} (#{rewritten}/#{total})"
            )

          {rewritten, total}
        else
          {rendered, total}
        end
      end)

    rendered
  end

  defp validation_rewrite_started_message(0), do: "No URLs to rewrite"
  defp validation_rewrite_started_message(1), do: "Rewriting 1 URL..."
  defp validation_rewrite_started_message(total), do: "Rewriting #{total} URLs..."

  defp validation_render_data(plan) do
    data = generation_data(plan)

    translations_by_post_language =
      data.translations_by_post
      |> flattened_generation_translations()
      |> translation_lookup_map()

    translatable_posts =
      Enum.reject(data.published_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

    translatable_list_posts =
      Enum.reject(data.published_list_posts, &truthy_flag?(Map.get(&1, :do_not_translate)))

    localized_posts_by_language =
      Map.new(additional_languages(plan), fn language ->
        {language,
         resolve_posts_for_language(
           translatable_posts,
           language,
           translations_by_post_language,
           plan.language
         )}
      end)

    localized_list_posts_by_language =
      Map.new(additional_languages(plan), fn language ->
        {language,
         resolve_posts_for_language(
           translatable_list_posts,
           language,
           translations_by_post_language,
           plan.language
         )}
      end)

    localized_post_indexes =
      Map.new(localized_list_posts_by_language, fn {language, posts} ->
        {language, build_generation_post_index(posts)}
      end)

    %{
      data: data,
      translations_by_post_language: translations_by_post_language,
      localized_posts_by_language: localized_posts_by_language,
      localized_list_posts_by_language: localized_list_posts_by_language,
      localized_post_indexes: localized_post_indexes
    }
  end

  defp build_targeted_section_outputs(plan, render_data, targeted_plan, :core) do
    data = render_data.data

    main_root =
      if targeted_plan.request_root_routes do
        posts = build_list_posts(plan.base_url, data.published_list_posts, nil)
        build_root_outputs(plan, plan.language, posts)
      else
        []
      end

    language_root =
      Enum.flat_map(additional_languages(plan), fn language ->
        language_plan = language_targeted_plan(targeted_plan, language)

        if language_plan.request_root_routes do
          source = Map.get(render_data.localized_list_posts_by_language, language, [])
          prefix = route_language(plan.language, language)
          posts = build_list_posts(plan.base_url, source, prefix)
          build_root_outputs(plan, language, posts)
        else
          []
        end
      end)

    main_page_posts =
      Enum.filter(
        data.published_posts,
        &MapSet.member?(targeted_plan.requested_page_slugs, &1.slug)
      )

    localized_page_posts =
      Map.new(additional_languages(plan), fn language ->
        language_plan = language_targeted_plan(targeted_plan, language)
        source = Map.get(render_data.localized_posts_by_language, language, [])
        {language, Enum.filter(source, &MapSet.member?(language_plan.requested_page_slugs, &1.slug))}
      end)

    page_outputs =
      build_page_outputs(
        plan.project_id,
        plan.language,
        main_page_posts,
        render_data.translations_by_post_language,
        localized_page_posts
      )

    main_root ++ language_root ++ page_outputs
  end

  defp build_targeted_section_outputs(plan, render_data, targeted_plan, :single) do
    data = render_data.data

    main_posts =
      filter_route_posts(data.published_posts, targeted_plan.requested_post_routes)

    localized_posts =
      Map.new(additional_languages(plan), fn language ->
        language_plan = language_targeted_plan(targeted_plan, language)
        source = Map.get(render_data.localized_posts_by_language, language, [])
        {language, filter_route_posts(source, language_plan.requested_post_routes)}
      end)

    build_single_outputs(
      plan.project_id,
      plan.language,
      main_posts,
      render_data.translations_by_post_language,
      localized_posts
    )
  end

  defp build_targeted_section_outputs(plan, render_data, targeted_plan, :category) do
    build_targeted_archive_outputs(plan, render_data, targeted_plan, fn plan_arg,
                                                                        index,
                                                                        language_plan,
                                                                        languages ->
      build_category_outputs(
        plan_arg,
        filter_collection_by_segment(index.posts_by_category, language_plan.requested_category_slugs),
        languages
      )
    end)
  end

  defp build_targeted_section_outputs(plan, render_data, targeted_plan, :tag) do
    build_targeted_archive_outputs(plan, render_data, targeted_plan, fn plan_arg,
                                                                        index,
                                                                        language_plan,
                                                                        languages ->
      build_tag_outputs(
        plan_arg,
        filter_collection_by_segment(index.posts_by_tag, language_plan.requested_tag_slugs),
        languages
      )
    end)
  end

  defp build_targeted_section_outputs(plan, render_data, targeted_plan, :date) do
    build_targeted_archive_outputs(plan, render_data, targeted_plan, fn plan_arg,
                                                                        index,
                                                                        language_plan,
                                                                        languages ->
      build_date_outputs(plan_arg, filter_date_index(index, language_plan), languages)
    end)
  end

  defp build_targeted_archive_outputs(plan, render_data, targeted_plan, builder) do
    main_outputs = builder.(plan, render_data.data.post_index, targeted_plan, [plan.language])

    language_outputs =
      Enum.flat_map(additional_languages(plan), fn language ->
        language_plan = language_targeted_plan(targeted_plan, language)
        index = Map.get(render_data.localized_post_indexes, language, empty_generation_post_index())
        builder.(plan, index, language_plan, [language])
      end)

    main_outputs ++ language_outputs
  end

  defp language_targeted_plan(targeted_plan, language) do
    Map.get(targeted_plan.language_plans, language, empty_validation_path_plan())
  end

  defp filter_route_posts(posts, route_keys) do
    Enum.filter(posts, fn post ->
      {year, month, day} = local_date_parts!(post.created_at)
      MapSet.member?(route_keys, route_key(year, month, day, post.slug))
    end)
  end

  defp filter_collection_by_segment(collection, segment_slugs) do
    collection
    |> Enum.filter(fn {key, _posts} ->
      MapSet.member?(segment_slugs, archive_route_segment(key))
    end)
    |> Map.new()
  end

  defp filter_date_index(index, language_plan) do
    %{
      posts_by_year: filter_map_by_keys(index.posts_by_year, language_plan.requested_years),
      posts_by_year_month:
        filter_map_by_keys(index.posts_by_year_month, language_plan.requested_year_months),
      posts_by_year_month_day:
        filter_map_by_keys(index.posts_by_year_month_day, language_plan.requested_year_month_days)
    }
  end

  defp filter_map_by_keys(map, keys) do
    map
    |> Enum.filter(fn {key, _value} -> MapSet.member?(keys, key) end)
    |> Map.new()
  end

  defp empty_generation_post_index do
    %{
      posts_by_category: %{},
      posts_by_tag: %{},
      posts_by_year: %{},
      posts_by_year_month: %{},
      posts_by_year_month_day: %{}
    }
  end

  defp validation_apply_sections_to_render(targeted_plan) do
    if fallback_validation_section_render?(targeted_plan) do
      [:category, :tag, :date, :core, :single]
    else
      targeted_plan
      |> validation_apply_section_plans()
      |> Enum.reduce([], &append_validation_apply_sections/2)
    end
  end

  defp fallback_validation_section_render?(%{requires_fallback_section_render: true}), do: true

  defp fallback_validation_section_render?(%{language_plans: language_plans}) do
    Enum.any?(Map.values(language_plans), &fallback_validation_section_render?/1)
  end

  defp validation_apply_section_plans(targeted_plan) do
    [targeted_plan | Map.values(Map.get(targeted_plan, :language_plans, %{}))]
  end

  defp append_validation_apply_sections(plan, sections) do
    sections
    |> maybe_append_validation_apply_section(:core, validation_apply_core_section?(plan))
    |> maybe_append_validation_apply_section(
      :single,
      not MapSet.equal?(plan.requested_post_routes, MapSet.new())
    )
    |> maybe_append_validation_apply_section(
      :category,
      not MapSet.equal?(plan.requested_category_slugs, MapSet.new())
    )
    |> maybe_append_validation_apply_section(
      :tag,
      not MapSet.equal?(plan.requested_tag_slugs, MapSet.new())
    )
    |> maybe_append_validation_apply_section(:date, validation_apply_date_section?(plan))
  end

  defp validation_apply_core_section?(plan) do
    plan.request_root_routes or not MapSet.equal?(plan.requested_page_slugs, MapSet.new())
  end

  defp validation_apply_date_section?(plan) do
    not MapSet.equal?(plan.requested_years, MapSet.new()) or
      not MapSet.equal?(plan.requested_year_months, MapSet.new()) or
      not MapSet.equal?(plan.requested_year_month_days, MapSet.new())
  end

  defp maybe_append_validation_apply_section(sections, _section, false), do: sections

  defp maybe_append_validation_apply_section(sections, section, true) do
    if section in sections, do: sections, else: sections ++ [section]
  end

  defp path_section(relative_path) do
    segments = String.split(relative_path, "/", trim: true)

    case strip_language_prefix(segments) do
      ["404.html"] ->
        :core

      ["index.html"] ->
        :core

      ["page", _page, "index.html"] ->
        :core

      ["sitemap.xml"] ->
        :core

      ["feed.xml"] ->
        :core

      ["atom.xml"] ->
        :core

      ["calendar.json"] ->
        :core

      ["pagefind" | _rest] ->
        :core

      [year, month, day, "index.html"]
      when byte_size(year) == 4 and byte_size(month) == 2 and byte_size(day) == 2 ->
        :date

      [year, month, day, _slug, "index.html"]
      when byte_size(year) == 4 and byte_size(month) == 2 and byte_size(day) == 2 ->
        :single

      ["category" | _rest] ->
        :category

      ["tag" | _rest] ->
        :tag

      [year, "index.html"] when byte_size(year) == 4 ->
        :date

      [year, month, "index.html"] when byte_size(year) == 4 and byte_size(month) == 2 ->
        :date

      _other ->
        :core
    end
  end

  defp strip_language_prefix([language | rest]) when language in ["en", "de", "fr", "it", "es"],
    do: rest

  defp strip_language_prefix(segments), do: segments

  defp list_published_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id and post.status == :published,
        order_by: [asc: post.created_at, asc: post.slug]
    )
  end

  defp normalize_sections(sections) do
    sections
    |> Enum.filter(&(&1 in @core_sections))
    |> Enum.uniq()
    |> case do
      [] -> [:core]
      values -> values
    end
  end

  defp upsert_generated_file_hash(project_id, relative_path, content_hash, now) do
    %GeneratedFileHash{}
    |> GeneratedFileHash.changeset(%{
      project_id: project_id,
      relative_path: relative_path,
      content_hash: content_hash,
      updated_at: now
    })
    |> Repo.insert!(
      on_conflict: [set: [content_hash: content_hash, updated_at: now]],
      conflict_target: [:project_id, :relative_path]
    )

    :ok
  end

  defp validation_section_task_label(:core), do: "Render Site Core"
  defp validation_section_task_label(:single), do: "Render Single Posts"
  defp validation_section_task_label(:category), do: "Render Category Archives"
  defp validation_section_task_label(:tag), do: "Render Tag Archives"
  defp validation_section_task_label(:date), do: "Render Date Archives"

  defp ancillary_validation_progress_label(:calendar), do: "calendar files"

  defp ancillary_validation_task_label(:calendar), do: "Regenerate Calendar"

  defp delete_extra_validation_paths(project_id, project, extra_url_paths) do
    delete_extra_validation_paths(project_id, project, extra_url_paths, nil)
  end

  defp delete_extra_validation_paths(project_id, project, extra_url_paths, on_progress) do
    total = length(extra_url_paths)

    if total == 0 do
      :ok = report_validation_progress(on_progress, 0.5, "No extra URLs to delete")
    end

    extra_url_paths
    |> Enum.with_index(1)
    |> Enum.reduce({0, 0}, fn {url_path, index}, {deleted_count, removed_dir_count} ->
      relative_path = url_path_to_relative_index_path(url_path)
      full_path = output_path(project, relative_path)

      result =
        case File.rm(full_path) do
          :ok ->
            Repo.delete_all(
              from generated_file in GeneratedFileHash,
                where:
                  generated_file.project_id == ^project_id and
                    generated_file.relative_path == ^relative_path
            )

            {pruned_count, _last_dir} =
              prune_empty_parent_dirs(Path.dirname(full_path), output_path(project, ""))

            {deleted_count + 1, removed_dir_count + pruned_count}

          {:error, :enoent} ->
            {deleted_count, removed_dir_count}

          {:error, _reason} ->
            {deleted_count, removed_dir_count}
        end

      :ok =
        report_validation_progress(
          on_progress,
          0.2 + 0.3 * index / max(total, 1),
          "Deleted #{index}/#{total} extra URLs"
        )

      result
    end)
  end

  defp ancillary_validation_paths(expected_output_map, :calendar) do
    expected_output_map
    |> Map.keys()
    |> Enum.filter(&(&1 == "calendar.json"))
  end

  defp output_path(project, relative_path) do
    Path.join([Projects.project_data_dir(project), "html", relative_path])
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
