defmodule BDS.Generation do
  @moduledoc false

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
    with {:ok, plan} <- plan_generation(project_id, @core_sections) do
      expected_outputs = build_outputs(plan)
      expected_output_map = Map.new(expected_outputs)
      project = Projects.get_project!(project_id)
      published_posts = list_published_posts(project_id)

      targeted_plan =
        build_targeted_validation_plan(
          plan_validation_paths(report_paths(report), additional_languages(plan)),
          published_posts
        )

      outputs_to_render =
        expected_outputs
        |> Enum.filter(fn {relative_path, _content} ->
          targeted_output?(
            relative_path,
            targeted_plan,
            plan.language,
            additional_languages(plan)
          )
        end)

      Enum.each(outputs_to_render, fn {relative_path, content} ->
        _ =
          write_generated_file(project_id, relative_path, content,
            refresh_timestamp_on_unchanged: route_html_path?(relative_path)
          )
      end)

      {deleted_url_count, removed_empty_dir_count} =
        delete_extra_validation_paths(project_id, project, Map.get(report, :extra_url_paths, []))

      if outputs_to_render != [] or deleted_url_count > 0 do
        write_ancillary_validation_outputs(project_id, expected_output_map)
      end

      {:ok,
       %{
         rendered_url_count:
           Enum.count(outputs_to_render, fn {relative_path, _content} ->
             route_html_path?(relative_path)
           end),
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

  defp build_outputs(plan) do
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
          localized_list_posts_by_language
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
          localized_posts_by_language
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
          localized_posts_by_language
        )
      else
        []
      end

    archive_outputs =
      build_archive_outputs(plan, data.post_index, localized_post_indexes)

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

  defp delete_extra_validation_paths(project_id, project, extra_url_paths) do
    Enum.reduce(extra_url_paths, {0, 0}, fn url_path, {deleted_count, removed_dir_count} ->
      relative_path = url_path_to_relative_index_path(url_path)
      full_path = output_path(project, relative_path)

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
    end)
  end

  defp write_ancillary_validation_outputs(project_id, expected_output_map) do
    ancillary_paths =
      Enum.filter(Map.keys(expected_output_map), fn relative_path ->
        relative_path == "calendar.json" or String.contains?(relative_path, "pagefind/")
      end)

    Enum.each(ancillary_paths, fn relative_path ->
      _ =
        write_generated_file(
          project_id,
          relative_path,
          Map.fetch!(expected_output_map, relative_path)
        )
    end)

    :ok
  end

  defp output_path(project, relative_path) do
    Path.join([Projects.project_data_dir(project), "html", relative_path])
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
