defmodule BDS.Desktop.ShellCommands do
  @moduledoc false

  alias BDS.Embeddings
  alias BDS.Generation
  alias BDS.Maintenance
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Preview
  alias BDS.Projects
  alias BDS.Publishing
  alias BDS.Search
  alias BDS.Tasks

  @site_sections [:core, :single, :category, :tag, :date]
  @rebuild_phase_timeout 600_000

  def execute(action, params \\ %{})

  def execute(action, params) when is_atom(action) do
    execute(Atom.to_string(action), params)
  end

  def execute(action, params) when is_binary(action) and is_map(params) do
    with {:ok, project} <- active_project() do
      dispatch(action, project, params)
    end
  end

  defp dispatch("open_in_browser", project, _params) do
    with {:ok, server} <- Preview.start_preview(project.id) do
      {:ok,
       %{
         kind: "open_url",
         action: "open_in_browser",
         title: "Open in Browser",
         message: "Preview server ready",
         project_id: project.id,
         url: preview_url(server)
       }}
    end
  end

  defp dispatch("preview_post", project, _params) do
    with {:ok, server} <- Preview.start_preview(project.id) do
      {:ok,
       %{
         kind: "open_url",
         action: "preview_post",
         title: "Preview Post",
         message: "Preview server ready",
         project_id: project.id,
         url: preview_url(server)
       }}
    end
  end

  defp dispatch("open_data_folder", project, _params) do
    path = Projects.project_data_dir(project)

    case open_system_path(path) do
      :ok ->
        {:ok,
         %{
           kind: "output",
           action: "open_data_folder",
           title: "Open Data Folder",
           message: path,
           project_id: project.id,
           level: "info"
         }}

      {:error, reason} ->
        {:error, %{action: "open_data_folder", message: "#{path}: #{inspect(reason)}"}}
    end
  end

  defp dispatch("reindex_text", project, _params) do
    group_id = task_group_id("reindex_text")
    attrs = %{group_id: group_id, group_name: "Search"}

    {:ok, posts_task} =
      Tasks.submit_task(
        "Reindex Search Text",
        fn report ->
          :ok = Search.reindex_posts(project.id, on_progress: report)
          report.(1.0, "Post search text reindexed")
          %{project_id: project.id, entity: "posts"}
        end,
        attrs
      )

    {:ok, _media_task} =
      Tasks.submit_task(
        "Reindex Media Search Text",
        fn report ->
          :ok = Search.reindex_media(project.id, on_progress: report)
          report.(1.0, "Media search text reindexed")
          %{project_id: project.id, entity: "media"}
        end,
        attrs
      )

    {:ok,
     %{
       kind: "task_queued",
       action: "reindex_text",
       title: "Reindex Text",
       message: "Search tasks queued",
       project_id: project.id,
       task_id: posts_task.id,
       task_group_id: group_id,
       panel_tab: "tasks"
     }}
  end

  defp dispatch("rebuild_embedding_index", project, _params) do
    queue_task(
      project,
      "rebuild_embedding_index",
      "Rebuild Embedding Index",
      "Embeddings",
      fn report ->
        {:ok, rebuilt_post_ids} = Embeddings.rebuild_project(project.id, on_progress: report)
        report.(1.0, "Embedding index rebuilt")

        %{
          project_id: project.id,
          rebuilt_post_ids: rebuilt_post_ids,
          rebuilt_count: length(rebuilt_post_ids)
        }
      end
    )
  end

  defp dispatch("rebuild_posts_from_files", project, _params) do
    queue_task(
      project,
      "rebuild_posts_from_files",
      "Rebuild Posts From Files",
      "Maintenance",
      fn report ->
        {:ok, posts} =
          Maintenance.rebuild_from_filesystem(project.id, "post", on_progress: report)

        report.(1.0, "Post rebuild complete")
        %{project_id: project.id, counts: %{posts: length(posts)}}
      end
    )
  end

  defp dispatch("rebuild_media_from_files", project, _params) do
    queue_task(
      project,
      "rebuild_media_from_files",
      "Rebuild Media From Files",
      "Maintenance",
      fn report ->
        {:ok, media} =
          Maintenance.rebuild_from_filesystem(project.id, "media", on_progress: report)

        report.(1.0, "Media rebuild complete")
        %{project_id: project.id, counts: %{media: length(media)}}
      end
    )
  end

  defp dispatch("rebuild_scripts_from_files", project, _params) do
    queue_task(
      project,
      "rebuild_scripts_from_files",
      "Rebuild Scripts From Files",
      "Maintenance",
      fn report ->
        {:ok, scripts} =
          Maintenance.rebuild_from_filesystem(project.id, "script", on_progress: report)

        report.(1.0, "Script rebuild complete")
        %{project_id: project.id, counts: %{scripts: length(scripts)}}
      end
    )
  end

  defp dispatch("rebuild_templates_from_files", project, _params) do
    queue_task(
      project,
      "rebuild_templates_from_files",
      "Rebuild Templates From Files",
      "Maintenance",
      fn report ->
        {:ok, templates} =
          Maintenance.rebuild_from_filesystem(project.id, "template", on_progress: report)

        report.(1.0, "Template rebuild complete")
        %{project_id: project.id, counts: %{templates: length(templates)}}
      end
    )
  end

  defp dispatch("rebuild_post_links", project, _params) do
    queue_task(project, "rebuild_post_links", "Rebuild Post Links", "Maintenance", fn report ->
      :ok = Posts.rebuild_post_links(project.id, on_progress: report)
      report.(1.0, "Post links rebuilt")
      %{project_id: project.id}
    end)
  end

  defp dispatch("regenerate_missing_thumbnails", project, _params) do
    queue_task(
      project,
      "regenerate_missing_thumbnails",
      "Regenerate Missing Thumbnails",
      "Maintenance",
      fn report ->
        result = BDS.Media.regenerate_missing_thumbnails(project.id, on_progress: report)
        report.(1.0, "Missing thumbnails regenerated")
        Map.put(result, :project_id, project.id)
      end
    )
  end

  defp dispatch("rebuild_database", project, _params) do
    group_id = task_group_id("rebuild_database")
    attrs = %{group_id: group_id, group_name: "Maintenance"}
    [first_step | remaining_steps] = rebuild_database_steps(project)

    {:ok, posts_task} =
      Tasks.submit_task(first_step.name, first_step.work, attrs)

    Task.start(fn ->
      case wait_for_group_phase(group_id, [first_step.name], @rebuild_phase_timeout) do
        :ok -> run_rebuild_sequence(group_id, attrs, remaining_steps)
        _other -> :ok
      end
    end)

    {:ok,
     %{
       kind: "task_queued",
       action: "rebuild_database",
       title: "Rebuild Database",
       message: "Maintenance tasks queued",
       project_id: project.id,
       task_id: posts_task.id,
       task_group_id: group_id,
       panel_tab: "tasks"
     }}
  end

  defp dispatch("generate_sitemap", project, _params) do
    queue_task(project, "generate_sitemap", "Generate Site", "Generation", fn report ->
      {:ok, generation} =
        Generation.generate_site(project.id, @site_sections, on_progress: report)

      report.(1.0, "Generated site output")

      %{
        project_id: project.id,
        sections: generation.sections,
        generated_count: length(generation.generated_files)
      }
    end)
  end

  defp dispatch("validate_site", project, _params) do
    queue_task(project, "validate_site", "Validate Site", "Validation", fn report ->
      {:ok, validation} =
        Generation.validate_site(project.id, @site_sections, on_progress: report)

      site_validation_result(project.id, validation)
    end)
  end

  defp dispatch("metadata_diff", project, _params) do
    queue_task(project, "metadata_diff", "Metadata Diff", "Maintenance", fn report ->
      {:ok, metadata_diff} = Maintenance.metadata_diff(project.id, on_progress: report)
      report.(1.0, "Metadata diff complete")
      metadata_diff_result(project.id, metadata_diff)
    end)
  end

  defp dispatch("repair_metadata_diff", project, params) do
    items = normalize_metadata_diff_items(BDS.MapUtils.attr(params, :items, []))
    direction = BDS.MapUtils.attr(params, :direction)

    if items == [] do
      {:error, %{action: "repair_metadata_diff", message: "No metadata diff items selected"}}
    else
      queue_task(
        project,
        "repair_metadata_diff",
        "Repair Metadata Diff",
        "Maintenance",
        fn report ->
          {:ok, _repair} =
            Maintenance.repair_metadata_diff(project.id, direction, items,
              on_progress: scaled_progress_reporter(report, 0.0, 0.8)
            )

          {:ok, metadata_diff} =
            Maintenance.metadata_diff(project.id,
              on_progress: scaled_progress_reporter(report, 0.8, 0.98)
            )

          report.(1.0, "Metadata diff repair complete")
          metadata_diff_result(project.id, metadata_diff)
        end
      )
    end
  end

  defp dispatch("import_metadata_diff_orphans", project, params) do
    orphans = normalize_metadata_diff_orphans(BDS.MapUtils.attr(params, :orphans, []))

    if orphans == [] do
      {:error, %{action: "import_metadata_diff_orphans", message: "No orphan files selected"}}
    else
      queue_task(
        project,
        "import_metadata_diff_orphans",
        "Import Metadata Diff Orphans",
        "Maintenance",
        fn report ->
          {:ok, _import} =
            Maintenance.import_metadata_diff_orphans(project.id, orphans,
              on_progress: scaled_progress_reporter(report, 0.0, 0.8)
            )

          {:ok, metadata_diff} =
            Maintenance.metadata_diff(project.id,
              on_progress: scaled_progress_reporter(report, 0.8, 0.98)
            )

          report.(1.0, "Metadata diff import complete")
          metadata_diff_result(project.id, metadata_diff)
        end
      )
    end
  end

  defp dispatch("validate_translations", project, _params) do
    queue_task(
      project,
      "validate_translations",
      "Validate Translations",
      "Validation",
      fn report ->
        {:ok, translation_report} = Posts.validate_translations(project.id, on_progress: report)
        report.(1.0, "Translation validation complete")
        translation_validation_result(project.id, translation_report)
      end
    )
  end

  defp dispatch("find_duplicates", project, _params) do
    queue_task(project, "find_duplicates", "Find Duplicate Posts", "Embeddings", fn report ->
      {:ok, pairs} = Embeddings.find_duplicates(project.id, on_progress: report)
      report.(1.0, "Duplicate search complete")
      duplicate_search_result(project.id, pairs)
    end)
  end

  defp dispatch("upload_site", project, _params) do
    with {:ok, metadata} <- Metadata.get_project_metadata(project.id),
         {:ok, credentials} <- upload_credentials(metadata.publishing_preferences),
         {:ok, job} <- Publishing.upload_site(project.id, credentials) do
      {:ok,
       %{
         kind: "task_queued",
         action: "upload_site",
         title: "Upload Site",
         message: "Upload queued",
         project_id: project.id,
         task_id: job.task_id,
         publish_job_id: job.id,
         panel_tab: "tasks"
       }}
    end
  end

  defp dispatch(action, _project, _params) do
    {:error, %{action: action, message: "Unsupported shell command"}}
  end

  defp queue_task(project, action, title, group_name, work) do
    {:ok, task} =
      Tasks.submit_task(title, work, %{
        group_id: project.id,
        group_name: group_name
      })

    {:ok,
     %{
       kind: "task_queued",
       action: action,
       title: title,
       message: "#{title} queued",
       project_id: project.id,
       task_id: task.id,
       panel_tab: "tasks"
     }}
  end

  defp scaled_progress_reporter(report, start_value, end_value) when is_function(report, 2) do
    fn value, message ->
      scaled_value = start_value + (end_value - start_value) * value
      report.(scaled_value, message)
    end
  end

  defp rebuild_database_steps(project) do
    [
      %{
        name: "Rebuild Posts From Files",
        work: fn report ->
          {:ok, posts} =
            Maintenance.rebuild_from_filesystem(project.id, "post",
              on_progress: report,
              rebuild_embeddings: false
            )

          report.(1.0, "Post rebuild complete")
          %{project_id: project.id, counts: %{posts: length(posts)}}
        end
      },
      %{
        name: "Rebuild Media From Files",
        work: fn report ->
          {:ok, media} =
            Maintenance.rebuild_from_filesystem(project.id, "media", on_progress: report)

          report.(1.0, "Media rebuild complete")
          %{project_id: project.id, counts: %{media: length(media)}}
        end
      },
      %{
        name: "Rebuild Scripts From Files",
        work: fn report ->
          {:ok, scripts} =
            Maintenance.rebuild_from_filesystem(project.id, "script", on_progress: report)

          report.(1.0, "Script rebuild complete")
          %{project_id: project.id, counts: %{scripts: length(scripts)}}
        end
      },
      %{
        name: "Rebuild Templates From Files",
        work: fn report ->
          {:ok, templates} =
            Maintenance.rebuild_from_filesystem(project.id, "template", on_progress: report)

          report.(1.0, "Template rebuild complete")
          %{project_id: project.id, counts: %{templates: length(templates)}}
        end
      },
      %{
        name: "Rebuild Post Links",
        work: fn report ->
          :ok = Posts.rebuild_post_links(project.id, on_progress: report)
          report.(1.0, "Post links rebuilt")
          %{project_id: project.id}
        end
      },
      %{
        name: "Regenerate Missing Thumbnails",
        work: fn report ->
          result = BDS.Media.regenerate_missing_thumbnails(project.id, on_progress: report)
          report.(1.0, "Missing thumbnails regenerated")
          Map.put(result, :project_id, project.id)
        end
      },
      %{
        name: "Rebuild Embedding Index",
        work: fn report ->
          {:ok, rebuilt_post_ids} = Embeddings.rebuild_project(project.id, on_progress: report)
          report.(1.0, "Embedding index rebuilt")

          %{
            project_id: project.id,
            rebuilt_post_ids: rebuilt_post_ids,
            rebuilt_count: length(rebuilt_post_ids)
          }
        end
      }
    ]
  end

  defp run_rebuild_sequence(_group_id, _attrs, []), do: :ok

  defp run_rebuild_sequence(group_id, attrs, [step | remaining_steps]) do
    {:ok, _task} = Tasks.submit_task(step.name, step.work, attrs)

    case wait_for_group_phase(group_id, [step.name], @rebuild_phase_timeout) do
      :ok -> run_rebuild_sequence(group_id, attrs, remaining_steps)
      _other -> :ok
    end
  end

  defp wait_for_group_phase(_group_id, _names, timeout) when timeout <= 0, do: :timeout

  defp wait_for_group_phase(group_id, names, timeout) do
    tasks =
      BDS.Tasks.list_tasks()
      |> Enum.filter(&(&1.group_id == group_id and &1.name in names))

    cond do
      length(tasks) < length(names) ->
        Process.sleep(50)
        wait_for_group_phase(group_id, names, timeout - 50)

      Enum.any?(tasks, &(&1.status == :failed)) ->
        :failed

      Enum.all?(tasks, &(&1.status == :completed)) ->
        :ok

      true ->
        Process.sleep(50)
        wait_for_group_phase(group_id, names, timeout - 50)
    end
  end

  defp task_group_id(action) do
    action <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp active_project do
    case Projects.get_active_project() do
      nil -> {:error, %{message: "No active project selected"}}
      project -> {:ok, project}
    end
  rescue
    error in [Exqlite.Error] ->
      if String.contains?(Exception.message(error), "no such table: projects") do
        {:error, %{message: "Project database is not initialized"}}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp preview_url(server) do
    "http://#{server.host}:#{server.port}/"
  end

  defp normalize_site_validation(report) do
    %{
      sitemap_path: report.sitemap_path,
      sitemap_changed: report.sitemap_changed,
      summary: %{
        expected_count: report.expected_url_count,
        existing_count: report.existing_html_url_count,
        missing_count: length(report.missing_url_paths),
        extra_count: length(report.extra_url_paths),
        updated_count: length(report.updated_post_url_paths)
      },
      missing_url_paths: report.missing_url_paths,
      extra_url_paths: report.extra_url_paths,
      updated_post_url_paths: report.updated_post_url_paths,
      expected_url_count: report.expected_url_count,
      existing_html_url_count: report.existing_html_url_count
    }
  end

  defp site_validation_result(project_id, report) do
    %{
      kind: "open_editor",
      action: "validate_site",
      project_id: project_id,
      route: "site_validation",
      title: "Site Validation",
      subtitle: "Generated output checked against expected site files",
      editorMeta: [
        %{label: "Expected", value: Integer.to_string(report.expected_url_count)},
        %{label: "Existing", value: Integer.to_string(report.existing_html_url_count)},
        %{label: "Missing", value: Integer.to_string(length(report.missing_url_paths))},
        %{label: "Extra", value: Integer.to_string(length(report.extra_url_paths))},
        %{label: "Updated", value: Integer.to_string(length(report.updated_post_url_paths))}
      ],
      payload: normalize_site_validation(report)
    }
  end

  defp normalize_metadata_diff(report) do
    %{
      summary: %{
        diff_count: length(report.diff_reports),
        orphan_count: length(report.orphan_reports)
      },
      diff_reports: Enum.map(report.diff_reports, &stringify_map/1),
      orphan_reports: Enum.map(report.orphan_reports, &stringify_map/1)
    }
  end

  defp metadata_diff_result(project_id, report) do
    %{
      kind: "open_editor",
      action: "metadata_diff",
      project_id: project_id,
      route: "metadata_diff",
      title: "Metadata Diff",
      subtitle: "Database state compared against filesystem metadata",
      editorMeta: [
        %{label: "Diffs", value: Integer.to_string(length(report.diff_reports))},
        %{label: "Orphans", value: Integer.to_string(length(report.orphan_reports))}
      ],
      payload: normalize_metadata_diff(report)
    }
  end

  defp normalize_translation_validation(report) do
    %{
      checked_database_row_count: report.checked_database_row_count,
      checked_filesystem_file_count: report.checked_filesystem_file_count,
      invalid_database_rows: Enum.map(report.invalid_database_rows, &stringify_map/1),
      invalid_filesystem_files: Enum.map(report.invalid_filesystem_files, &stringify_map/1)
    }
  end

  defp translation_validation_result(project_id, report) do
    %{
      kind: "open_editor",
      action: "validate_translations",
      project_id: project_id,
      route: "translation_validation",
      title: "Translation Validation",
      subtitle: "Database rows and translation files checked for invalid state",
      editorMeta: [
        %{label: "Invalid DB", value: Integer.to_string(length(report.invalid_database_rows))},
        %{
          label: "Invalid Files",
          value: Integer.to_string(length(report.invalid_filesystem_files))
        }
      ],
      payload: normalize_translation_validation(report)
    }
  end

  defp normalize_duplicate_pairs(pairs) do
    %{
      summary: %{pair_count: length(pairs)},
      pairs: Enum.map(pairs, &stringify_map/1)
    }
  end

  defp duplicate_search_result(project_id, pairs) do
    %{
      kind: "open_editor",
      action: "find_duplicates",
      project_id: project_id,
      route: "find_duplicates",
      title: "Find Duplicates",
      subtitle: "Potential duplicate posts found via embeddings",
      editorMeta: [%{label: "Pairs", value: Integer.to_string(length(pairs))}],
      payload: normalize_duplicate_pairs(pairs)
    }
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp normalize_metadata_diff_items(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        entity_type: BDS.MapUtils.attr(item, :entity_type),
        entity_id: BDS.MapUtils.attr(item, :entity_id)
      }
    end)
  end

  defp normalize_metadata_diff_items(_items), do: []

  defp normalize_metadata_diff_orphans(orphans) when is_list(orphans) do
    Enum.map(orphans, fn orphan ->
      %{file_path: BDS.MapUtils.attr(orphan, :file_path)}
    end)
  end

  defp normalize_metadata_diff_orphans(_orphans), do: []

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp upload_credentials(prefs) when is_map(prefs) do
    credentials = %{
      ssh_host: Map.get(prefs, "ssh_host"),
      ssh_user: Map.get(prefs, "ssh_user"),
      ssh_remote_path: Map.get(prefs, "ssh_remote_path"),
      ssh_mode: Map.get(prefs, "ssh_mode")
    }

    if Enum.all?(
         [credentials.ssh_host, credentials.ssh_user, credentials.ssh_remote_path],
         &is_binary/1
       ) do
      {:ok, credentials}
    else
      {:error, %{action: "upload_site", message: "Publishing preferences are incomplete"}}
    end
  end

  defp open_system_path(path) do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [path]}
        {:unix, _other} -> {"xdg-open", [path]}
        {:win32, _other} -> {"cmd", ["/c", "start", "", path]}
      end

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end
end
