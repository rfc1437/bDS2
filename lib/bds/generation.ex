defmodule BDS.Generation do
  @moduledoc false

  import Ecto.Query

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Generation.GeneratedFileHash
  alias BDS.Metadata
  alias BDS.Persistence
  alias BDS.PreviewAssets
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Rendering
  alias BDS.Repo
  alias BDS.Slug

  @core_sections [:core, :single, :category, :tag, :date]

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

  def generate_site(project_id, sections \\ [:core], opts \\ [])

  def generate_site(project_id, sections, opts)
      when is_binary(project_id) and is_list(sections) and is_list(opts) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      outputs = build_outputs(plan)
      on_progress = progress_callback(opts)
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

  def validate_site(project_id, sections \\ @core_sections, opts \\ [])

  def validate_site(project_id, sections, opts) when is_binary(project_id) and is_list(sections) and is_list(opts) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      on_progress = progress_callback(opts)
      data = generation_data(plan)
      generated_file_updated_at = generated_file_updated_at_map(project_id)

      :ok = report_validation_progress(on_progress, 0.0, "Collecting sitemap URLs...")

      sitemap_content =
        plan
        |> build_validation_route_paths(data, on_progress)
        |> Enum.map(&url_for_output(plan.base_url, &1))
        |> render_sitemap()

      {:ok, sitemap_write} =
        write_generated_file(project_id, "sitemap.xml", sitemap_content)

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
              plan.language,
              data.published_posts,
              flattened_generation_translations(data.translations_by_post),
              generated_file_updated_at
            )
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

  defp progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  defp report_generation_started(nil, _total, _label), do: :ok

  defp report_generation_started(callback, 0, label) do
    callback.(1.0, "No #{label} to process")
    :ok
  end

  defp report_generation_started(callback, total, label) do
    callback.(0.0, "Processing 0/#{total} #{label}")
    :ok
  end

  defp report_generation_progress(nil, _current, _total, _label), do: :ok
  defp report_generation_progress(_callback, _current, 0, _label), do: :ok

  defp report_generation_progress(callback, current, total, label) do
    callback.(current / total, "Processing #{current}/#{total} #{label}")
    :ok
  end

  defp report_validation_progress(nil, _progress, _message), do: :ok

  defp report_validation_progress(callback, progress, message) do
    callback.(progress, message)
    :ok
  end

  defp report_validation_collection_progress(nil, _current, _total), do: :ok
  defp report_validation_collection_progress(_callback, _current, total) when total <= 0, do: :ok

  defp report_validation_collection_progress(callback, current, total) do
    progress = min(0.49, current / total * 0.5)
    callback.(progress, "Collecting sitemap URLs... #{current}/#{total}")
    :ok
  end

  def apply_validation(project_id, sections) when is_binary(project_id) and is_list(sections) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      expected_outputs = build_outputs(plan)
      expected_paths = MapSet.new(Enum.map(expected_outputs, &elem(&1, 0)))
      actual_files = disk_generated_files(project_id)
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

      disk_generated_files(project_id)
      |> Map.keys()
      |> Enum.filter(fn relative_path ->
        path_section(relative_path) in plan.sections and not MapSet.member?(expected_paths, relative_path)
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
          targeted_output?(relative_path, targeted_plan, plan.language, additional_languages(plan))
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
         rendered_url_count: Enum.count(outputs_to_render, fn {relative_path, _content} -> route_html_path?(relative_path) end),
         deleted_url_count: deleted_url_count,
         removed_empty_dir_count: removed_empty_dir_count
       }}
    end
  end

  def post_output_path(post), do: post_output_path(post, nil)

  def post_output_path(post, language) when is_map(post) do
    datetime = Persistence.from_unix_ms!(post.created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = datetime.day |> Integer.to_string() |> String.pad_leading(2, "0")

    path_parts = [year, month, day, post.slug, "index.html"]

    case language do
      nil -> Path.join(path_parts)
      "" -> Path.join(path_parts)
      value -> Path.join([value | path_parts])
    end
  end

  def write_generated_file(project_id, relative_path, content),
    do: write_generated_file(project_id, relative_path, content, [])

  def write_generated_file(project_id, relative_path, content, opts)
      when is_binary(project_id) and is_binary(relative_path) and is_binary(content) and is_list(opts) do
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

  def list_generated_files(project_id) when is_binary(project_id) do
    {:ok,
     Repo.all(
       from generated_file in GeneratedFileHash,
         where: generated_file.project_id == ^project_id,
         order_by: [asc: generated_file.relative_path]
     )}
  end

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

  defp generation_data(plan) do
    project = Projects.get_project!(plan.project_id)
    project_data_dir = Projects.project_data_dir(project)
    list_excluded_categories = excluded_list_categories(plan)

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

    snapshots_by_id =
      (published_candidates ++ draft_candidates)
      |> Enum.reduce(%{}, fn post, acc ->
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
        |> Enum.reduce(Map.new(published, &{&1.id, &1}), fn post, acc -> Map.put(acc, post.id, post) end)
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
      build_generation_route_posts(plan.project_id, project_data_dir, published_posts)

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

    Enum.reduce(Map.get(plan, :category_settings, %{}) || %{}, defaults, fn {category, settings}, acc ->
      Map.put(acc, category, %{
        render_in_lists: category_setting_flag(settings, :render_in_lists, "render_in_lists", true),
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

        %Post{fallback_post |
          id: DocumentFields.get(fields, "id", fallback_post.id),
          title: DocumentFields.get(fields, "title", fallback_post.title) || "",
          slug: DocumentFields.fetch!(fields, "slug"),
          excerpt: Map.get(fields, "excerpt"),
          content: nil,
          status: :published,
          author: Map.get(fields, "author"),
          language: Map.get(fields, "language", fallback_post.language),
          do_not_translate: DocumentFields.get(fields, "doNotTranslate", fallback_post.do_not_translate || false),
          template_slug: DocumentFields.get(fields, "templateSlug", fallback_post.template_slug),
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

  defp build_generation_route_posts(project_id, project_data_dir, published_posts) do
    source_post_ids = Enum.map(published_posts, & &1.id)

    translation_candidates =
      Repo.all(
        from translation in Translation,
          where: translation.project_id == ^project_id and translation.translation_for in ^source_post_ids,
          where: translation.status in [:published, :draft],
          order_by: [asc: translation.translation_for, asc: translation.language]
      )

    translations_by_post =
      translation_candidates
      |> Enum.reduce(%{}, fn translation, acc ->
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

  defp flattened_generation_translations(translations_by_post) do
    translations_by_post
    |> Map.values()
    |> List.flatten()
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

        %Translation{fallback_translation |
          id: DocumentFields.get(fields, "id", fallback_translation.id),
          translation_for: DocumentFields.fetch!(fields, "translationFor"),
          language: DocumentFields.fetch!(fields, "language"),
          title: DocumentFields.get(fields, "title", fallback_translation.title) || "",
          excerpt: Map.get(fields, "excerpt", fallback_translation.excerpt),
          content: nil,
          status: :published,
          created_at: DocumentFields.get(fields, "createdAt", fallback_translation.created_at),
          updated_at: DocumentFields.get(fields, "updatedAt", fallback_translation.updated_at),
          published_at: DocumentFields.get(fields, "publishedAt", fallback_translation.published_at),
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
      author: Map.get(post, :author),
      created_at: post.created_at,
      updated_at: translation.updated_at,
      published_at: translation.published_at || post.published_at,
      file_path: translation.file_path,
      tags: Map.get(post, :tags, []),
      categories: Map.get(post, :categories, []),
      template_slug: Map.get(post, :template_slug),
      language: translation.language,
      do_not_translate: Map.get(post, :do_not_translate, false),
      translation_source_slug: post.slug,
      translation_canonical_language: Map.get(post, :language),
      translation_file_path: translation.file_path
    }
  end

  defp build_generation_post_index(posts) do
    Enum.reduce(posts, %{posts_by_category: %{}, posts_by_tag: %{}, posts_by_year: %{}, posts_by_year_month: %{}, posts_by_year_month_day: %{}}, fn post, acc ->
      created_at = Persistence.from_unix_ms!(post.created_at)
      year = created_at.year
      month = String.pad_leading(Integer.to_string(created_at.month), 2, "0")
      day = String.pad_leading(Integer.to_string(created_at.day), 2, "0")
      year_month = "#{year}/#{month}"
      year_month_day = "#{year}/#{month}/#{day}"

      acc
      |> append_generation_index(:posts_by_year, year, post)
      |> append_generation_index(:posts_by_year_month, year_month, post)
      |> append_generation_index(:posts_by_year_month_day, year_month_day, post)
      |> then(fn indexed ->
        indexed = Enum.reduce(post.categories || [], indexed, &append_generation_index(&2, :posts_by_category, &1, post))
        Enum.reduce(post.tags || [], indexed, &append_generation_index(&2, :posts_by_tag, &1, post))
      end)
    end)
  end

  defp append_generation_index(index, field, key, post) do
    update_in(index[field], fn grouped -> Map.update(grouped, key, [post], &[post | &1]) end)
  end

  defp build_outputs(plan) do
    data = generation_data(plan)
    published_translations = flattened_generation_translations(data.translations_by_post)
    post_by_id = Map.new(data.published_posts, &{&1.id, &1})

    core_outputs =
      if :core in plan.sections do
        build_core_outputs(plan, data.published_list_posts)
      else
        []
      end

    page_outputs =
      if :core in plan.sections do
        build_page_outputs(plan.project_id, plan.language, data.published_posts, published_translations, post_by_id)
      else
        []
      end

    single_outputs =
      if :single in plan.sections do
        build_single_outputs(
          plan.project_id,
          plan.language,
          data.published_posts,
          published_translations,
          post_by_id
        )
      else
        []
      end

    archive_outputs =
      build_archive_outputs(plan, data.published_list_posts, data.post_index)

    urls =
      (core_outputs ++ page_outputs ++ single_outputs ++ archive_outputs)
      |> Enum.filter(fn {relative_path, _content} -> sitemap_route_output?(relative_path) end)
      |> Enum.map(fn {relative_path, _content} ->
        url_for_output(plan.base_url, relative_path)
      end)

    sitemap =
      if :core in plan.sections do
        [{"sitemap.xml", render_sitemap(urls)}]
      else
        []
      end

    pagefind_outputs =
      if :core in plan.sections do
        build_pagefind_outputs(plan, core_outputs ++ page_outputs ++ single_outputs ++ archive_outputs)
      else
        []
      end

    asset_outputs =
      if :core in plan.sections do
        PreviewAssets.generated_outputs()
      else
        []
      end

    core_outputs ++ page_outputs ++ single_outputs ++ archive_outputs ++ sitemap ++ pagefind_outputs ++ asset_outputs
  end

  defp build_validation_route_paths(plan, data, on_progress) do
    _ = data

    route_paths =
      plan
      |> build_outputs()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&route_html_path?/1)

    total_route_count = length(route_paths)

    route_paths
    |> Enum.with_index(1)
    |> Enum.map(fn {relative_path, index} ->
      :ok = report_validation_collection_progress(on_progress, index, total_route_count)
      relative_path
    end)
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
        |> Enum.map(fn path ->
          relative_path = Path.relative_to(path, html_root)

          {relative_path,
           path
           |> File.read!()
           |> sha256()}
        end)
        |> Map.new()

      {:error, :enoent} ->
        %{}
    end
  end

  defp path_section(relative_path) do
    segments = String.split(relative_path, "/", trim: true)

    case strip_language_prefix(segments) do
      ["404.html"] -> :core
      ["index.html"] -> :core
      ["page", _page, "index.html"] -> :core
      ["sitemap.xml"] -> :core
      ["feed.xml"] -> :core
      ["atom.xml"] -> :core
      ["calendar.json"] -> :core
      ["pagefind" | _rest] -> :core
      [year, month, day, "index.html"] when byte_size(year) == 4 and byte_size(month) == 2 and byte_size(day) == 2 -> :date
      [year, month, day, _slug, "index.html"] when byte_size(year) == 4 and byte_size(month) == 2 and byte_size(day) == 2 -> :single
      ["category" | _rest] -> :category
      ["tag" | _rest] -> :tag
      [year, "index.html"] when byte_size(year) == 4 -> :date
      [year, month, "index.html"] when byte_size(year) == 4 and byte_size(month) == 2 -> :date
      _other -> :core
    end
  end

  defp strip_language_prefix([language | rest]) when language in ["en", "de", "fr", "it", "es"],
    do: rest

  defp strip_language_prefix(segments), do: segments

  defp build_archive_outputs(plan, _published_posts, post_index) do
    languages = plan.blog_languages

    category_outputs =
      if :category in plan.sections do
        build_category_outputs(plan, post_index.posts_by_category, languages)
      else
        []
      end

    tag_outputs =
      if :tag in plan.sections do
        build_tag_outputs(plan, post_index.posts_by_tag, languages)
      else
        []
      end

    date_outputs =
      if :date in plan.sections do
        build_date_outputs(plan, post_index, languages)
      else
        []
      end

    category_outputs ++ tag_outputs ++ date_outputs
  end

  defp build_category_outputs(plan, posts_by_category, languages) do
    Enum.flat_map(posts_by_category, fn {category, posts} ->
      paginated_posts = Enum.chunk_every(posts, max(plan.max_posts_per_page, 1))
      category_slug = Slug.slugify(category)

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

  defp build_tag_outputs(plan, posts_by_tag, languages) do
    Enum.flat_map(posts_by_tag, fn {tag, posts} ->
      tag_slug = Slug.slugify(tag)

      build_paginated_archive_outputs(plan, languages, ["tag", tag_slug], posts, fn page_posts, language, pagination ->
        render_archive_page(plan, tag, page_posts, language, "tag", pagination)
      end)
    end)
  end

  defp build_date_outputs(plan, post_index, languages) do
    year_outputs =
      Enum.flat_map(post_index.posts_by_year, fn {year, posts} ->
        build_paginated_archive_outputs(plan, languages, [Integer.to_string(year)], posts, fn page_posts, language, pagination ->
          render_date_archive_page(
            plan,
            Integer.to_string(year),
            %{kind: "year", year: year},
            page_posts,
            language,
            pagination
          )
        end)
      end)

    month_outputs =
      Enum.flat_map(post_index.posts_by_year_month, fn {year_month, posts} ->
        [year, month] = String.split(year_month, "/", parts: 2)

        build_paginated_archive_outputs(plan, languages, [year, month], posts, fn page_posts, language, pagination ->
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

        build_paginated_archive_outputs(plan, languages, [year, month, day], posts, fn page_posts, language, pagination ->
          render_date_archive_page(
            plan,
            "#{year}-#{month}-#{day}",
            %{kind: "day", year: String.to_integer(year), month: String.to_integer(month), day: String.to_integer(day)},
            page_posts,
            language,
            pagination
          )
        end)
      end)

    year_outputs ++ month_outputs ++ day_outputs
  end

  defp build_core_outputs(plan, published_posts) do
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
        localized_posts = build_list_posts(plan.base_url, published_posts, localized_prefix)

        build_root_outputs(plan, localized_language, localized_posts) ++
          [
            {Path.join(localized_language, "404.html"), render_not_found_output(plan, localized_language)},
            {Path.join(localized_language, "feed.xml"), render_feed(plan, localized_language, published_posts)},
            {Path.join(localized_language, "atom.xml"), render_atom(plan, localized_language, published_posts)}
          ]
      end)
  end

  defp build_page_outputs(project_id, main_language, published_posts, published_translations, post_by_id) do
    translations_by_post_language =
      Map.new(published_translations, fn translation ->
        {{translation.translation_for, translation.language}, translation}
      end)

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
           fn -> render_post_page(canonical_variant.title, body, post.slug, canonical_variant.language) end
         )}
      end)

    translation_page_outputs =
      published_posts
      |> Enum.filter(&("page" in (&1.categories || [])))
      |> Enum.flat_map(fn post ->
        post_variant =
          if post.language == main_language do
            []
          else
            [{post.language, post}]
          end

        translation_variants =
          published_translations
          |> Enum.filter(&(&1.translation_for == post.id and &1.language != main_language))
          |> Enum.map(&{&1.language, &1})

        Enum.map(post_variant ++ translation_variants, fn {language, variant} ->
          canonical_post = Map.get(post_by_id, post.id, post)
          body = load_body(project_id, variant.file_path, variant.content)

          {page_output_path(canonical_post.slug, language),
           render_post_output(
             project_id,
             canonical_post.template_slug,
             %{
               id: variant.id,
               title: variant.title,
               content: body,
               slug: canonical_post.slug,
               language: variant.language,
               excerpt: variant.excerpt
             },
             fn -> render_post_page(variant.title, body, canonical_post.slug, variant.language) end
           )}
        end)
      end)

    page_outputs ++ translation_page_outputs
  end

  defp build_root_outputs(plan, language, posts) do
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
         pagination_for_page(page_number, total_pages, length(posts), plan.max_posts_per_page, route_language, []),
         fn -> render_home(plan, language) end
       )}
    end)
  end

  defp build_paginated_archive_outputs(plan, languages, segments, posts, render_fun) do
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
           pagination_for_page(page_number, total_pages, length(posts), plan.max_posts_per_page, route_language, segments)
         )}
      end)
    end)
  end

  defp root_output_path(nil, 1), do: "index.html"
  defp root_output_path("", 1), do: "index.html"
  defp root_output_path(route_language, 1), do: Path.join(route_language, "index.html")
  defp root_output_path(nil, page_number), do: Path.join(["page", Integer.to_string(page_number), "index.html"])
  defp root_output_path("", page_number), do: root_output_path(nil, page_number)
  defp root_output_path(route_language, page_number), do: Path.join([route_language, "page", Integer.to_string(page_number), "index.html"])

  defp page_output_path(slug, nil), do: Path.join([slug, "index.html"])
  defp page_output_path(slug, ""), do: page_output_path(slug, nil)
  defp page_output_path(slug, language), do: Path.join([language, slug, "index.html"])

  defp pagination_for_page(page_number, total_pages, total_items, items_per_page, route_language, segments) do
    %{
      current_page: page_number,
      total_pages: total_pages,
      total_items: total_items,
      items_per_page: items_per_page,
      has_prev_page: page_number > 1,
      prev_page_href: archive_or_root_href(route_language, segments, page_number - 1),
      has_next_page: page_number < total_pages,
      next_page_href: archive_or_root_href(route_language, segments, page_number + 1)
    }
  end

  defp archive_or_root_href(_route_language, _segments, page_number) when page_number < 1, do: ""
  defp archive_or_root_href(route_language, [], page_number), do: root_page_href(route_language, page_number)
  defp archive_or_root_href(route_language, segments, page_number), do: archive_href(route_language, segments, page_number)

  defp root_page_href(route_language, page_number) when page_number <= 1 do
    case route_language do
      nil -> "/"
      "" -> "/"
      language -> "/#{language}/"
    end
  end

  defp root_page_href(route_language, page_number) do
    base =
      case route_language do
        nil -> ""
        "" -> ""
        language -> "/#{language}"
      end

    "#{base}/page/#{page_number}/"
  end

  defp page_count(total_items, _max_posts_per_page) when total_items <= 0, do: 1

  defp page_count(total_items, max_posts_per_page) do
    page_size = max(max_posts_per_page, 1)
    div(total_items + page_size - 1, page_size)
  end

  defp paginate_posts(posts, max_posts_per_page) do
    case Enum.chunk_every(posts, max(max_posts_per_page, 1)) do
      [] -> [[]]
      chunks -> chunks
    end
  end

  defp build_single_outputs(
         project_id,
         main_language,
         published_posts,
         published_translations,
         post_by_id
       ) do
    translations_by_post_language =
      Map.new(published_translations, fn translation ->
        {{translation.translation_for, translation.language}, translation}
      end)

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
             render_post_page(canonical_variant.title, body, post.slug, canonical_variant.language)
           end
         )}
      end)

    translation_outputs =
      post_outputs_for_noncanonical_variants(
        project_id,
        main_language,
        published_posts,
        published_translations,
        post_by_id
      )

    post_outputs ++ translation_outputs
  end

  defp post_outputs_for_noncanonical_variants(
         project_id,
         main_language,
         published_posts,
         published_translations,
         post_by_id
       ) do
    Enum.flat_map(published_posts, fn post ->
      post_variant =
        if post.language == main_language do
          []
        else
          [{post.language, post}]
        end

      translation_variants =
        published_translations
        |> Enum.filter(&(&1.translation_for == post.id and &1.language != main_language))
        |> Enum.map(&{&1.language, &1})

      (post_variant ++ translation_variants)
      |> Enum.flat_map(fn {language, variant} ->
        canonical_post = Map.get(post_by_id, post.id, post)
        body = load_body(project_id, variant.file_path, variant.content)

        [
          {post_output_path(canonical_post, language),
           render_post_output(
             project_id,
             canonical_post.template_slug,
             %{
               id: variant.id,
               title: variant.title,
               content: body,
               slug: canonical_post.slug,
               language: variant.language,
               excerpt: variant.excerpt
             },
             fn ->
               render_post_page(variant.title, body, canonical_post.slug, variant.language)
             end
           )}
        ]
      end)
    end)
  end

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

  defp archive_path(language, segments, 1), do: archive_path(language, segments)

  defp archive_path(language, segments, page_number) do
    archive_path(language, segments ++ ["page", Integer.to_string(page_number)])
  end

  defp archive_path(nil, segments), do: Path.join(segments ++ ["index.html"])
  defp archive_path("", segments), do: Path.join(segments ++ ["index.html"])

  defp archive_path(language, segments) do
    prefix = if language in [nil, ""], do: [], else: [language]
    Path.join(prefix ++ segments ++ ["index.html"])
  end

  defp normalize_base_url(nil), do: nil
  defp normalize_base_url(url), do: String.trim_trailing(url, "/")

  defp normalize_blog_languages(main_language, blog_languages) do
    ([main_language] ++ (blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp route_language(main_language, language) when main_language == language, do: nil
  defp route_language(_main_language, language), do: language

  defp render_home(plan, language) do
    [
      "<html>",
      "<head><title>",
      plan.project_name,
      "</title></head>",
      "<body data-language=\"",
      to_string(language),
      "\"><main><h1>",
      plan.project_name,
      "</h1></main></body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_feed(plan, language, published_posts) do
    items =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<item><title>#{xml_escape(post.title)}</title><link>#{url_for_output(plan.base_url, post_output_path(post))}</link></item>"
      end)
      |> Enum.join()

    "<rss><channel><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{items}</channel></rss>"
  end

  defp render_atom(plan, language, published_posts) do
    entries =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<entry><title>#{xml_escape(post.title)}</title><id>#{url_for_output(plan.base_url, post_output_path(post))}</id></entry>"
      end)
      |> Enum.join()

    "<feed><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{entries}</feed>"
  end

  defp render_calendar(published_posts) do
    published_posts
    |> Enum.map(fn post ->
      datetime = Persistence.from_unix_ms!(post.created_at)
      %{date: Date.to_iso8601(DateTime.to_date(datetime)), slug: post.slug, title: post.title}
    end)
    |> Jason.encode!()
  end

  defp render_sitemap(urls) do
    entries = Enum.map_join(urls, "", fn url -> "<url><loc>#{xml_escape(url)}</loc></url>" end)
    "<urlset>#{entries}</urlset>"
  end

  defp sitemap_route_output?("404.html"), do: false
  defp sitemap_route_output?("feed.xml"), do: false
  defp sitemap_route_output?("atom.xml"), do: false
  defp sitemap_route_output?("calendar.json"), do: false
  defp sitemap_route_output?(relative_path), do: String.ends_with?(relative_path, ".html")

  defp build_pagefind_outputs(plan, html_outputs) do
    language_outputs =
      plan.blog_languages
      |> Enum.uniq()
      |> Enum.flat_map(fn language ->
        route_language = route_language(plan.language, language)
        pages = pagefind_pages_for_language(html_outputs, route_language)
        prefix = if route_language in [nil, ""], do: ["pagefind"], else: [route_language, "pagefind"]

        [
          {Path.join(prefix ++ ["index.json"]), Jason.encode!(%{"language" => language, "pages" => pages})},
          {Path.join(prefix ++ ["pagefind-ui.js"]), pagefind_ui_js(language)},
          {Path.join(prefix ++ ["pagefind-ui.css"]), pagefind_ui_css()}
        ]
      end)

    language_outputs
  end

  defp pagefind_pages_for_language(html_outputs, route_language) do
    html_outputs
    |> Enum.filter(fn {relative_path, _content} ->
      String.ends_with?(relative_path, ".html") and pagefind_language_match?(relative_path, route_language)
    end)
    |> Enum.map(fn {relative_path, content} ->
      %{
        "url" => "/" <> relative_path,
        "text" => pagefind_text(content)
      }
    end)
  end

  defp pagefind_language_match?(relative_path, nil), do: not String.starts_with?(relative_path, ["de/", "fr/", "it/", "es/"])
  defp pagefind_language_match?(relative_path, ""), do: pagefind_language_match?(relative_path, nil)
  defp pagefind_language_match?(relative_path, route_language), do: String.starts_with?(relative_path, route_language <> "/")

  defp pagefind_text(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp pagefind_ui_js(language) do
    "window.bDSPagefind = { language: #{Jason.encode!(language)} };\n"
  end

  defp pagefind_ui_css do
    ".pagefind-ui{display:block;}\n"
  end

  defp render_post_page(title, body, slug, language) do
    [
      "<html>",
      "<head><title>",
      to_string(title),
      "</title></head>",
      "<body data-slug=\"",
      to_string(slug),
      "\" data-language=\"",
      to_string(language),
      "\"><article data-pagefind-body>",
      body,
      "</article></body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_archive_page(plan, title, posts, language, kind, pagination) do
    fallback = fn ->
      items =
        posts
        |> Enum.map(fn post -> ["<li>", post.title, "</li>"] end)
        |> IO.iodata_to_binary()

      [
        "<html><body data-kind=\"",
        kind,
        "\" data-language=\"",
        to_string(language),
        "\"><h1>",
        title,
        "</h1><ul>",
        items,
        "</ul></body></html>"
      ]
      |> IO.iodata_to_binary()
    end

    render_list_output(
      plan,
      language,
      title,
      Enum.map(posts, fn post ->
        %{
          id: post.id,
          slug: post.slug,
          title: post.title,
          href: "#",
          excerpt: post.excerpt,
          content: nil,
          language: post.language
        }
      end),
      %{kind: kind, name: title},
      pagination,
      fallback
    )
  end

  defp render_date_archive_page(plan, label, archive_context, posts, language, pagination) do
    fallback = fn ->
      items =
        posts
        |> Enum.map(fn post -> ["<li>", post.title, "</li>"] end)
        |> IO.iodata_to_binary()

      [
        "<html><body data-kind=\"date\" data-language=\"",
        to_string(language),
        "\"><h1>",
        label,
        "</h1><ul>",
        items,
        "</ul></body></html>"
      ]
      |> IO.iodata_to_binary()
    end

    render_list_output(
      plan,
      language,
      label,
      build_list_posts(plan.base_url, posts, route_language(plan.language, language)),
      archive_context,
      pagination,
      fallback
    )
  end

  defp load_body(_project_id, _file_path, inline_content) when is_binary(inline_content),
    do: inline_content

  defp load_body(project_id, file_path, _inline_content) do
    case file_path do
      nil ->
        ""

      "" ->
        ""

      value ->
        project_path =
          Path.expand(value, Projects.project_data_dir(Projects.get_project!(project_id)))

        case File.read(project_path) do
          {:ok, contents} -> parse_frontmatter_body(contents)
          {:error, _reason} -> ""
        end
    end
  end

  defp parse_frontmatter_body(contents) do
    case String.split(contents, "\n---\n", parts: 2) do
      [_frontmatter, body] -> String.trim_trailing(body, "\n")
      _parts -> contents
    end
  end

  defp build_list_posts(base_url, posts, language_prefix) do
    Enum.map(posts, fn post ->
      %{
        id: post.id,
        slug: post.slug,
        title: post.title,
        href: url_for_output(base_url, post_output_path(post, language_prefix)),
        excerpt: post.excerpt,
        content: load_body(post.project_id, post.file_path, post.content)
      }
    end)
  end

  defp render_post_output(project_id, template_slug, assigns, fallback) do
    case Rendering.render_post_page(project_id, template_slug, assigns) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  defp render_list_output(
         %{project_id: project_id, language: main_language},
         language,
         page_title,
         posts,
         archive_context,
         pagination,
         fallback
       )
       when is_binary(project_id) do
    case Rendering.render_list_page(project_id, %{
           language: language,
           language_prefix: language_prefix(language, main_language),
           page_title: page_title,
           posts: posts,
           archive_context: archive_context,
           pagination: pagination
         }) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  defp render_not_found_output(%{project_id: project_id, language: main_language}, language)
       when is_binary(project_id) do
    case Rendering.render_not_found_page(project_id, %{
           language: language,
           language_prefix: language_prefix(language, main_language)
         }) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> render_not_found_page(language)
    end
  end

  defp language_prefix(language, main_language) when language == main_language, do: ""
  defp language_prefix(nil, _main_language), do: ""
  defp language_prefix(language, _main_language), do: "/#{language}"

  defp archive_href(language, segments, page_number) do
    archive_path(language, segments, page_number)
    |> String.trim_trailing("index.html")
    |> then(&("/" <> String.trim_leading(&1, "/")))
  end

  defp url_for_output(nil, relative_path), do: "/" <> String.trim_leading(relative_path, "/")

  defp url_for_output(base_url, relative_path) do
    cleaned = relative_path |> String.trim_leading("/") |> String.trim_trailing("index.html")
    suffix = if cleaned == "", do: "/", else: "/" <> cleaned
    String.trim_trailing(base_url, "/") <> suffix
  end

  defp render_not_found_page(language) do
    [
      "<html><body data-language=\"",
      to_string(language),
      "\"><section data-template=\"not-found\"><h1>404</h1><p>Not Found</p></section></body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
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

  defp generated_file_updated_at_map(project_id) do
    project_id
    |> list_generated_files()
    |> then(fn {:ok, files} -> Map.new(files, &{&1.relative_path, &1.updated_at}) end)
  end

  defp build_post_timestamp_checks(
      project_data_dir,
         main_language,
         published_posts,
         published_translations,
         generated_file_updated_at
       ) do
    translations_by_post_language =
      Map.new(published_translations, fn translation ->
        {{translation.translation_for, translation.language}, translation}
      end)

    post_by_id = Map.new(published_posts, &{&1.id, &1})

    canonical_checks =
      Enum.map(published_posts, fn post ->
        canonical_variant = Map.get(translations_by_post_language, {post.id, main_language}, post)
        relative_path = post_output_path(post)

        %{
          post_url_path: relative_path_to_url_path(relative_path),
          post_file_path: source_full_path(project_data_dir, canonical_variant.file_path),
          generated_updated_at_ms: Map.get(generated_file_updated_at, relative_path, 0)
        }
      end)

    translation_checks =
      Enum.flat_map(published_posts, fn post ->
        post_variant =
          if post.language == main_language do
            []
          else
            [{post.language, post}]
          end

        translation_variants =
          published_translations
          |> Enum.filter(&(&1.translation_for == post.id and &1.language != main_language))
          |> Enum.map(&{&1.language, &1})

        Enum.map(post_variant ++ translation_variants, fn {language, variant} ->
          canonical_post = Map.get(post_by_id, post.id, post)
          relative_path = post_output_path(canonical_post, language)

          %{
            post_url_path: relative_path_to_url_path(relative_path),
            post_file_path: source_full_path(project_data_dir, variant.file_path),
            generated_updated_at_ms: Map.get(generated_file_updated_at, relative_path, 0)
          }
        end)
      end)

    canonical_checks ++ translation_checks
  end

  defp source_full_path(_project_data_dir, file_path) when file_path in [nil, ""], do: nil

  defp source_full_path(project_data_dir, file_path) do
    Path.join(project_data_dir, file_path)
  end

  defp compare_sitemap_to_html(params) do
    post_timestamp_checks = Map.get(params, :post_timestamp_checks, [])
    index_paths = Path.wildcard(Path.join(params.html_dir, "**/index.html"))
    total_compare_steps = max(length(index_paths) + length(post_timestamp_checks), 1)

    expected_path_set =
      params.sitemap_xml
      |> extract_sitemap_locs()
      |> Enum.map(&sitemap_loc_to_project_path(&1, params.base_url))
      |> MapSet.new()

    {existing_html_path_set, zero_byte_html_path_set} =
      collect_html_index_paths(index_paths, params.html_dir, params.on_progress, total_compare_steps)

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
            html_path = Path.join(params.html_dir, url_path_to_relative_index_path(normalized_url_path))

            case {File.stat(html_path, time: :posix), File.stat(check.post_file_path, time: :posix)} do
              {{:ok, html_stat}, {:ok, post_stat}} ->
                effective_generated_at_ms = max(mtime_ms(html_stat), check.generated_updated_at_ms || 0)

                if mtime_ms(post_stat) > effective_generated_at_ms do
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

  defp extract_sitemap_locs(sitemap_xml) do
    Regex.scan(~r/<loc>(.*?)<\/loc>/, sitemap_xml, capture: :all_but_first)
    |> Enum.map(fn [value] -> String.trim(value) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp sitemap_loc_to_project_path(loc, nil), do: normalize_url_path(loc)

  defp sitemap_loc_to_project_path(loc, base_url) do
    with {:ok, loc_uri} <- URI.new(loc),
         {:ok, base_uri} <- URI.new(base_url) do
      loc_path = String.trim_trailing(loc_uri.path || "/", "/")
      base_path = String.trim_trailing(base_uri.path || "", "/")

      cond do
        base_path != "" and String.starts_with?(loc_path, base_path) ->
          loc_path
          |> String.replace_prefix(base_path, "")
          |> normalize_url_path()

        true ->
          normalize_url_path(loc_path)
      end
    else
      _other -> normalize_url_path(loc)
    end
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

  defp report_validation_compare_progress(nil, _current, _total), do: :ok
  defp report_validation_compare_progress(_callback, _current, total) when total <= 0, do: :ok

  defp report_validation_compare_progress(callback, current, total) do
    progress = min(0.99, 0.5 + current / total * 0.49)
    callback.(progress, "Comparing sitemap to html pages... #{current}/#{total}")
    :ok
  end

  defp normalize_url_path(nil), do: "/"

  defp normalize_url_path(url_path) do
    trimmed = String.trim(url_path || "")

    cond do
      trimmed in ["", "/"] ->
        "/"

      true ->
        trimmed
        |> String.split(["?", "#"])
        |> List.first()
        |> to_string()
        |> String.trim("/")
        |> case do
          "" -> "/"
          value -> "/" <> value
        end
    end
  end

  defp relative_path_to_url_path(relative_path) do
    relative_path
    |> String.trim_leading("/")
    |> String.trim_trailing("index.html")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      value -> "/" <> value
    end
  end

  defp url_path_to_relative_index_path("/"), do: "index.html"

  defp url_path_to_relative_index_path(url_path) do
    url_path
    |> normalize_url_path()
    |> String.trim_leading("/")
    |> Path.join("index.html")
  end

  defp mtime_ms(%{mtime: mtime}) when is_integer(mtime) do
    mtime * 1000
  end

  defp mtime_ms(%{mtime: mtime}) do
    mtime
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp report_paths(report) do
    Map.get(report, :missing_url_paths, []) ++ Map.get(report, :updated_post_url_paths, [])
  end

  defp additional_languages(plan) do
    Enum.reject(plan.blog_languages, &(&1 == plan.language))
  end

  defp plan_validation_paths(paths, additional_languages) do
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

  defp empty_validation_path_plan do
    %{
      request_root_routes: false,
      requires_fallback_section_render: false,
      requested_category_slugs: MapSet.new(),
      requested_tag_slugs: MapSet.new(),
      requested_years: MapSet.new(),
      requested_year_months: MapSet.new(),
      requested_post_routes: [],
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
                update_in(plan.requested_post_routes, &[ %{year: String.to_integer(year), month: String.to_integer(month), day: String.to_integer(day), slug: slug} | &1 ])

              nil ->
                case Regex.run(~r|^/(\d{4})/(\d{2})(?:/page/\d+)?$|, path) do
                  [_, year, month] ->
                    update_in(plan.requested_year_months, &MapSet.put(&1, "#{year}/#{month}"))

                  nil ->
                    case Regex.run(~r|^/(\d{4})(?:/page/\d+)?$|, path) do
                      [_, year] ->
                        update_in(plan.requested_years, &MapSet.put(&1, String.to_integer(year)))

                      nil ->
                        if path == "/" or Regex.match?(~r|^/page/\d+$|, path) do
                          %{plan | request_root_routes: true}
                        else
                          %{plan | requires_fallback_section_render: true}
                        end
                    end
                end
            end
        end
    end
  end

  defp build_targeted_validation_plan(initial_plan, published_posts) do
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
        Enum.reduce(initial_plan.requested_post_routes, %{initial_plan | requested_post_routes: targeted_post_routes}, fn route, acc ->
          case Enum.find(published_posts, &post_matches_route?(&1, route)) do
            nil ->
              acc
              |> update_in([:requested_years], &MapSet.put(&1, route.year))
              |> update_in([:requested_year_months], &MapSet.put(&1, route_month_key(route.year, route.month)))
              |> Map.put(:request_root_routes, true)

            post ->
              created_at = Persistence.from_unix_ms!(post.created_at)
              year = created_at.year
              month = created_at.month

              acc
              |> update_in([:requested_category_slugs], fn set ->
                Enum.reduce(post.categories || [], set, &MapSet.put(&2, Slug.slugify(&1)))
              end)
              |> update_in([:requested_tag_slugs], fn set ->
                Enum.reduce(post.tags || [], set, &MapSet.put(&2, Slug.slugify(&1)))
              end)
              |> update_in([:requested_years], &MapSet.put(&1, year))
              |> update_in([:requested_year_months], &MapSet.put(&1, route_month_key(year, month)))
              |> Map.put(:request_root_routes, true)
          end
        end)

      language_plans =
        initial_plan.language_plans
        |> Enum.map(fn {language, language_plan} ->
          {language, build_targeted_validation_plan(language_plan, published_posts)}
        end)
        |> Map.new()

      %{
        enriched
        | requested_category_slugs: MapSet.intersection(enriched.requested_category_slugs, available_category_slugs),
          requested_tag_slugs: MapSet.intersection(enriched.requested_tag_slugs, available_tag_slugs),
          language_plans: language_plans
      }
    end
  end

  defp post_matches_route?(post, route) do
    created_at = Persistence.from_unix_ms!(post.created_at)

    post.slug == route.slug and created_at.year == route.year and created_at.month == route.month and
      created_at.day == route.day
  end

  defp route_key(year, month, day, slug) do
    "#{year}/#{String.pad_leading(Integer.to_string(month), 2, "0")}/#{String.pad_leading(Integer.to_string(day), 2, "0")}/#{slug}"
  end

  defp route_month_key(year, month) do
    "#{year}/#{String.pad_leading(Integer.to_string(month), 2, "0")}"
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

      _other -> {nil, path}
    end
  end

  defp targeted_output?(relative_path, targeted_plan, main_language, additional_languages) do
    {language, stripped_path} = extract_relative_output_language(relative_path, additional_languages)

    plan =
      case language do
        nil -> targeted_plan
        value -> Map.get(targeted_plan.language_plans, value, empty_validation_path_plan())
      end

    targeted_output_for_plan?(stripped_path, plan, main_language == language or is_nil(language))
  end

  defp extract_relative_output_language(relative_path, additional_languages) do
    segments = String.split(relative_path, "/", trim: true)

    case segments do
      [language | rest] ->
        if language in additional_languages do
          {language, Path.join(rest)}
        else
          {nil, relative_path}
        end

      _other ->
        {nil, relative_path}
    end
  end

  defp targeted_output_for_plan?(_relative_path, %{requires_fallback_section_render: true}, _main?), do: true

  defp targeted_output_for_plan?(relative_path, plan, _main?) do
    cond do
      relative_path in ["index.html", "404.html", "feed.xml", "atom.xml"] ->
        plan.request_root_routes

      Regex.match?(~r|^category/([^/]+)(?:/page/\d+)?/index\.html$|, relative_path) ->
        [_, slug] = Regex.run(~r|^category/([^/]+)(?:/page/\d+)?/index\.html$|, relative_path)
        MapSet.member?(plan.requested_category_slugs, slug)

      Regex.match?(~r|^tag/([^/]+)/index\.html$|, relative_path) ->
        [_, slug] = Regex.run(~r|^tag/([^/]+)/index\.html$|, relative_path)
        MapSet.member?(plan.requested_tag_slugs, slug)

      Regex.match?(~r|^(\d{4})/(\d{2})/(\d{2})/([^/]+)/index\.html$|, relative_path) ->
        [_, year, month, day, slug] = Regex.run(~r|^(\d{4})/(\d{2})/(\d{2})/([^/]+)/index\.html$|, relative_path)
        MapSet.member?(plan.requested_post_routes, route_key(String.to_integer(year), String.to_integer(month), String.to_integer(day), slug))

      Regex.match?(~r|^(\d{4})/(\d{2})/index\.html$|, relative_path) ->
        [_, year, month] = Regex.run(~r|^(\d{4})/(\d{2})/index\.html$|, relative_path)
        MapSet.member?(plan.requested_year_months, "#{year}/#{month}")

      Regex.match?(~r|^(\d{4})/index\.html$|, relative_path) ->
        [_, year] = Regex.run(~r|^(\d{4})/index\.html$|, relative_path)
        MapSet.member?(plan.requested_years, String.to_integer(year))

      true ->
        false
    end
  end

  defp route_html_path?(relative_path), do: String.ends_with?(relative_path, "index.html")

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

          {pruned_count, _last_dir} = prune_empty_parent_dirs(Path.dirname(full_path), output_path(project, ""))
          {deleted_count + 1, removed_dir_count + pruned_count}

        {:error, :enoent} ->
          {deleted_count, removed_dir_count}

        {:error, _reason} ->
          {deleted_count, removed_dir_count}
      end
    end)
  end

  defp prune_empty_parent_dirs(current_dir, html_root) do
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

  defp write_ancillary_validation_outputs(project_id, expected_output_map) do
    ancillary_paths =
      Enum.filter(Map.keys(expected_output_map), fn relative_path ->
        relative_path == "calendar.json" or String.contains?(relative_path, "pagefind/")
      end)

    Enum.each(ancillary_paths, fn relative_path ->
      _ = write_generated_file(project_id, relative_path, Map.fetch!(expected_output_map, relative_path))
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
