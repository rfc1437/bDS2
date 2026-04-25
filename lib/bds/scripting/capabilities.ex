defmodule BDS.Scripting.Capabilities do
  @moduledoc false
  @mix_env Mix.env()

  import Ecto.Query

  alias BDS.AI
  alias BDS.Desktop.FolderPicker
  alias BDS.Desktop.MenuBar
  alias BDS.Embeddings
  alias BDS.Git
  alias BDS.I18n
  alias BDS.Media
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Metadata
  alias BDS.MCP
  alias BDS.PostLinks
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Preview
  alias BDS.Publishing
  alias BDS.Projects
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Scripts
  alias BDS.Scripts.Script
  alias BDS.Tags
  alias BDS.Tags.Tag
  alias BDS.Tasks
  alias BDS.Templates
  alias BDS.Templates.Template

  def for_project(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    %{
      app: %{
        copy_to_clipboard: one_arg(fn text -> copy_to_clipboard(text, opts) end),
        get_data_paths: zero_or_one_arg(fn _args -> data_paths(project_id) end),
        get_blogmark_bookmarklet: zero_or_one_arg(fn _args -> blogmark_bookmarklet() end),
        get_system_language: zero_or_one_arg(fn _args -> I18n.current_ui_locale() end),
        get_default_project_path: zero_or_one_arg(fn _args -> project_path(project_id) end),
        get_title_bar_metrics: zero_or_one_arg(fn _args -> title_bar_metrics(opts) end),
        notify_renderer_ready: zero_or_one_arg(fn _args -> notify_renderer_ready(opts) end),
        open_folder: one_arg(fn folder_path -> open_folder(folder_path, opts) end),
        read_project_metadata: one_arg(fn folder_path -> read_project_metadata(folder_path) end),
        select_folder: one_arg(fn title -> select_folder(title, opts) end),
        set_preview_post_target: one_arg(fn post_id -> set_preview_post_target(post_id) end),
        show_item_in_folder: one_arg(fn item_path -> show_item_in_folder(item_path, opts) end),
        trigger_menu_action: one_arg(fn action -> trigger_menu_action(action, opts) end)
      },
      projects: %{
        create: zero_or_one_arg(fn attrs -> create_project(attrs) end),
        delete: one_arg(fn project_id_to_delete -> delete_project(project_id_to_delete) end),
        delete_with_data: one_arg(fn project_id_to_delete -> delete_project_with_data(project_id_to_delete) end),
        get: one_arg(fn project_id_to_load -> load_project(project_id_to_load) end),
        get_all: zero_or_one_arg(fn _args -> list_projects() end),
        get_active: zero_or_one_arg(fn _args -> load_project(project_id) end),
        set_active: one_arg(fn project_id_to_activate -> set_active_project(project_id_to_activate) end),
        update: two_arg(fn project_id_to_update, attrs -> update_project(project_id_to_update, attrs) end)
      },
      meta: %{
        get_project_metadata: zero_or_one_arg(fn _args -> load_metadata(project_id) end),
        update_project_metadata: one_arg(fn attrs -> update_project_metadata(project_id, attrs) end),
        add_category: one_arg(fn name -> add_category(project_id, name) end),
        remove_category: one_arg(fn name -> remove_category(project_id, name) end),
        add_tag: one_arg(fn name -> add_meta_tag(project_id, name) end),
        get_categories: zero_or_one_arg(fn _args -> metadata_categories(project_id) end),
        set_project_metadata: one_arg(fn attrs -> update_project_metadata(project_id, attrs) end),
        get_publishing_preferences: zero_or_one_arg(fn _args -> publishing_preferences(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> metadata_tags(project_id) end),
        remove_tag: one_arg(fn name -> remove_meta_tag(project_id, name) end),
        set_publishing_preferences: one_arg(fn prefs -> set_publishing_preferences(project_id, prefs) end),
        clear_publishing_preferences: zero_or_one_arg(fn _args -> clear_publishing_preferences(project_id) end),
        sync_on_startup: zero_or_one_arg(fn _args -> sync_meta_on_startup(project_id) end)
      },
      posts: %{
        create: one_arg(fn attrs -> create_post(project_id, attrs) end),
        discard: one_arg(fn post_id -> discard_post(project_id, post_id) end),
        filter: one_arg(fn filters -> filter_posts(project_id, filters) end),
        generate_unique_slug: two_arg(fn title, exclude_post_id -> generate_unique_post_slug(project_id, title, exclude_post_id) end),
        get_by_status: one_arg(fn status -> posts_by_status(project_id, status) end),
        get_by_year_month: zero_or_one_arg(fn _args -> post_counts_by_year_month(project_id) end),
        get_dashboard_stats: zero_or_one_arg(fn _args -> post_dashboard_stats(project_id) end),
        get_linked_by: one_arg(fn post_id -> linked_posts_for(project_id, post_id, :incoming) end),
        get_links_to: one_arg(fn post_id -> linked_posts_for(project_id, post_id, :outgoing) end),
        get_preview_url: two_arg(fn post_id, options -> preview_url(project_id, post_id, options) end),
        update: two_arg(fn post_id, attrs -> update_post(project_id, post_id, attrs) end),
        delete: one_arg(fn post_id -> delete_post(project_id, post_id) end),
        get: one_arg(fn post_id -> load_post(project_id, post_id) end),
        get_all: zero_or_one_arg(fn _args -> list_posts(project_id) end),
        get_by_slug: one_arg(fn slug -> load_post_by_slug(project_id, slug) end),
        get_categories: zero_or_one_arg(fn _args -> post_categories(project_id) end),
        get_categories_with_counts: zero_or_one_arg(fn _args -> post_categories_with_counts(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> post_tags(project_id) end),
        get_tags_with_counts: zero_or_one_arg(fn _args -> post_tags_with_counts(project_id) end),
        get_translation: two_arg(fn post_id, language -> load_post_translation(project_id, post_id, language) end),
        get_translations: one_arg(fn post_id -> list_post_translations(project_id, post_id) end),
        has_published_version: one_arg(fn post_id -> has_published_post_version(project_id, post_id) end),
        is_slug_available: two_arg(fn slug, exclude_post_id -> post_slug_available?(project_id, slug, exclude_post_id) end),
        publish: one_arg(fn post_id -> publish_post(project_id, post_id) end),
        publish_translation: two_arg(fn post_id, language -> publish_post_translation(project_id, post_id, language) end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_posts_from_files(project_id) end),
        rebuild_links: zero_or_one_arg(fn _args -> rebuild_post_links(project_id) end),
        reindex_text: zero_or_one_arg(fn _args -> reindex_project_search(project_id) end),
        search: one_arg(fn query -> search_posts(project_id, query) end)
      },
      media: %{
        delete_translation: two_arg(fn media_id, language -> delete_media_translation(project_id, media_id, language) end),
        filter: one_arg(fn filters -> filter_media(project_id, filters) end),
        import: one_arg(fn attrs -> import_media(project_id, attrs) end),
        get_by_year_month: zero_or_one_arg(fn _args -> media_counts_by_year_month(project_id) end),
        get_file_path: one_arg(fn media_id -> media_file_path(project_id, media_id) end),
        update: two_arg(fn media_id, attrs -> update_media(project_id, media_id, attrs) end),
        delete: one_arg(fn media_id -> delete_media(project_id, media_id) end),
        get: one_arg(fn media_id -> load_media(project_id, media_id) end),
        get_all: zero_or_one_arg(fn _args -> list_media(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> media_tags(project_id) end),
        get_tags_with_counts: zero_or_one_arg(fn _args -> media_tags_with_counts(project_id) end),
        get_thumbnail: two_arg(fn media_id, size -> media_thumbnail(project_id, media_id, size) end),
        get_translation: two_arg(fn media_id, language -> load_media_translation(project_id, media_id, language) end),
        get_translations: one_arg(fn media_id -> list_media_translations(project_id, media_id) end),
        get_url: one_arg(fn media_id -> media_url(project_id, media_id) end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_media_from_files(project_id) end),
        regenerate_missing_thumbnails: zero_or_one_arg(fn _args -> regenerate_missing_thumbnails(project_id) end),
        regenerate_thumbnails: one_arg(fn media_id -> regenerate_media_thumbnails(project_id, media_id) end),
        reindex_text: zero_or_one_arg(fn _args -> reindex_project_search(project_id) end),
        replace_file: two_arg(fn media_id, source_path -> replace_media_file(project_id, media_id, source_path) end),
        search: one_arg(fn query -> search_media(project_id, query) end),
        upsert_translation: three_arg(fn media_id, language, attrs -> upsert_media_translation(project_id, media_id, language, attrs) end)
      },
      scripts: %{
        create: one_arg(fn attrs -> create_script(project_id, attrs) end),
        update: two_arg(fn script_id, attrs -> update_script(project_id, script_id, attrs) end),
        delete: one_arg(fn script_id -> delete_script(project_id, script_id) end),
        get: one_arg(fn script_id -> load_script(project_id, script_id) end),
        get_all: zero_or_one_arg(fn _args -> list_scripts(project_id) end),
        publish: one_arg(fn script_id -> publish_script(project_id, script_id) end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_scripts_from_files(project_id) end)
      },
      templates: %{
        create: one_arg(fn attrs -> create_template(project_id, attrs) end),
        update: two_arg(fn template_id, attrs -> update_template(project_id, template_id, attrs) end),
        delete: one_arg(fn template_id -> delete_template(project_id, template_id) end),
        get: one_arg(fn template_id -> load_template(project_id, template_id) end),
        get_all: zero_or_one_arg(fn _args -> list_templates(project_id) end),
        publish: one_arg(fn template_id -> publish_template(project_id, template_id) end),
        get_enabled_by_kind: one_arg(fn kind -> list_enabled_templates(project_id, kind) end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_templates_from_files(project_id) end),
        validate: one_arg(fn source -> validate_template_source(source) end)
      },
      tags: %{
        create: one_arg(fn attrs -> create_tag(project_id, attrs) end),
        update: two_arg(fn tag_id, attrs -> update_tag(project_id, tag_id, attrs) end),
        delete: one_arg(fn tag_id -> delete_tag(project_id, tag_id) end),
        get: one_arg(fn tag_id -> load_tag(project_id, tag_id) end),
        get_all: zero_or_one_arg(fn _args -> list_tags(project_id) end),
        get_by_name: one_arg(fn tag_name -> load_tag_by_name(project_id, tag_name) end),
        get_posts_with_tag: one_arg(fn tag_id -> tag_post_ids(project_id, tag_id) end),
        get_with_counts: zero_or_one_arg(fn _args -> tags_with_counts(project_id) end),
        merge: two_arg(fn source_tag_ids, target_tag_id -> merge_tags(project_id, source_tag_ids, target_tag_id) end),
        rename: two_arg(fn tag_id, new_name -> rename_tag(project_id, tag_id, new_name) end),
        sync_from_posts: zero_or_one_arg(fn _args -> sync_tags_from_posts(project_id) end)
      },
      tasks: %{
        get: one_arg(fn task_id -> load_task(task_id) end),
        status_snapshot: zero_or_one_arg(fn _args -> sanitize(Tasks.status_snapshot()) end),
        cancel: one_arg(fn task_id -> cancel_task(task_id) end),
        get_all: zero_or_one_arg(fn _args -> list_all_tasks() end),
        get_running: zero_or_one_arg(fn _args -> list_running_tasks() end),
        clear_completed: zero_or_one_arg(fn _args -> clear_completed_tasks() end)
      },
      sync: %{
        check_availability: zero_or_one_arg(fn _args -> sync_available?() end),
        get_repo_state: zero_or_one_arg(fn _args -> repo_state(project_id, opts) end),
        get_status: zero_or_one_arg(fn _args -> repo_status(project_id, opts) end),
        get_history: zero_or_one_arg(fn _args -> repo_history(project_id, opts) end),
        get_remote_state: zero_or_one_arg(fn _args -> repo_state(project_id, opts) end),
        fetch: zero_or_one_arg(fn _args -> repo_fetch(project_id, opts) end),
        pull: zero_or_one_arg(fn _args -> repo_pull(project_id, opts) end),
        push: zero_or_one_arg(fn _args -> repo_push(project_id, opts) end),
        commit_all: one_arg(fn message -> repo_commit_all(project_id, message, opts) end)
      },
      publish: %{
        upload_site: one_arg(fn credentials -> upload_site(project_id, credentials, opts) end)
      },
      chat: %{
        detect_post_language: two_arg(fn title, content -> detect_post_language(title, content, opts) end),
        analyze_post: one_arg(fn post_id -> analyze_post(post_id, opts) end),
        translate_post: two_arg(fn post_id, language -> translate_post(post_id, language, opts) end),
        analyze_media_image: one_arg(fn media_id -> analyze_media_image(media_id, opts) end),
        detect_media_language: three_arg(fn title, alt, caption -> detect_media_language(title, alt, caption, opts) end),
        translate_media_metadata: two_arg(fn media_id, language -> translate_media_metadata(media_id, language, opts) end)
      },
      embeddings: %{
        get_progress: zero_or_one_arg(fn _args -> embedding_progress(project_id) end),
        find_similar: two_arg(fn post_id, limit -> find_similar(post_id, limit) end),
        compute_similarities: two_arg(fn post_id, target_ids -> compute_similarities(post_id, target_ids) end),
        suggest_tags: two_arg(fn post_id, exclude_tags -> suggest_tags(post_id, exclude_tags) end),
        find_duplicates: zero_or_one_arg(fn _args -> find_duplicates(project_id) end),
        dismiss_pair: two_arg(fn post_id_a, post_id_b -> dismiss_pair(post_id_a, post_id_b) end),
        index_unindexed_posts: zero_or_one_arg(fn _args -> index_unindexed_posts(project_id) end)
      }
    }
  end

  defp create_project(attrs), do: attrs |> normalize_map() |> Projects.create_project() |> unwrap_result()

  defp delete_project(project_id), do: boolean_result(Projects.delete_project(string_or_nil(project_id)))

  defp delete_project_with_data(project_id) do
    case string_or_nil(project_id) && Projects.get_project(string_or_nil(project_id)) do
      %Project{} = project ->
        data_dir = Projects.project_data_dir(project)

        case Projects.delete_project(project.id) do
          {:ok, _deleted_project} ->
            _ = File.rm_rf(data_dir)
            true

          {:error, _reason} ->
            false
        end

      _other ->
        false
    end
  end

  defp load_project(project_id) do
    case string_or_nil(project_id) do
      nil -> nil
      id -> Projects.get_project(id) |> sanitize_nilable()
    end
  end

  defp list_projects do
    Projects.list_projects()
    |> Enum.map(&sanitize/1)
  end

  defp set_active_project(project_id) do
    project_id
    |> string_or_nil()
    |> then(fn
      nil -> {:error, :not_found}
      id -> Projects.set_active_project(id)
    end)
    |> unwrap_result()
  end

  defp update_project(project_id, attrs) do
    case string_or_nil(project_id) && Projects.get_project(string_or_nil(project_id)) do
      %Project{} = project ->
        attrs = normalize_map(attrs)

        updates = %{
          name: Map.get(attrs, "name", project.name),
          description: Map.get(attrs, "description", project.description),
          data_path: Map.get(attrs, "data_path", project.data_path),
          updated_at: System.system_time(:millisecond),
          is_active: Map.get(attrs, "is_active", project.is_active)
        }

        project
        |> Project.changeset(updates)
        |> Repo.update()
        |> unwrap_result()

      _other ->
        nil
    end
  end

  defp load_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    sanitize(metadata)
  end

  defp update_project_metadata(project_id, attrs) do
    Metadata.update_project_metadata(project_id, normalize_map(attrs))
    |> unwrap_result()
  end

  defp add_category(project_id, name) do
    Metadata.add_category(project_id, string_or_nil(name) || "")
    |> unwrap_result()
  end

  defp remove_category(project_id, name) do
    Metadata.remove_category(project_id, string_or_nil(name) || "")
    |> unwrap_result()
  end

  defp metadata_categories(project_id) do
    load_metadata(project_id)
    |> Map.get("categories", [])
  end

  defp metadata_tags(project_id) do
    project_id
    |> list_tags()
    |> Enum.map(&Map.get(&1, "name"))
  end

  defp add_meta_tag(project_id, name) do
    normalized_name = string_or_nil(name) |> to_string() |> String.trim()

    cond do
      normalized_name == "" -> metadata_tags(project_id)
      load_tag_by_name(project_id, normalized_name) -> metadata_tags(project_id)
      true ->
        create_tag(project_id, %{"name" => normalized_name})
        metadata_tags(project_id)
    end
  end

  defp remove_meta_tag(project_id, name) do
    case load_tag_by_name(project_id, name) do
      %{"id" => tag_id} ->
        _ = delete_tag(project_id, tag_id)
        metadata_tags(project_id)

      _other ->
        metadata_tags(project_id)
    end
  end

  defp publishing_preferences(project_id) do
    load_metadata(project_id)
    |> Map.get("publishing_preferences")
  end

  defp set_publishing_preferences(project_id, prefs) do
    project_id
    |> Metadata.set_publishing_preferences(normalize_map(prefs))
    |> unwrap_result()
    |> case do
      nil -> nil
      metadata -> Map.get(metadata, "publishing_preferences")
    end
  end

  defp clear_publishing_preferences(project_id) do
    set_publishing_preferences(project_id, %{})
  end

  defp sync_meta_on_startup(project_id) do
    _ = Tags.sync_tags_from_posts(project_id)

    %{
      tags: metadata_tags(project_id),
      categories: metadata_categories(project_id),
      project_metadata: load_metadata(project_id)
    }
  end

  defp create_post(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Posts.create_post()
    |> unwrap_result(&post_payload/1)
  end

  defp update_post(project_id, post_id, attrs) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.update_post(post_id, normalize_map(attrs)) |> unwrap_result(&post_payload/1)
      _other -> nil
    end
  end

  defp delete_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> boolean_result(Posts.delete_post(post_id))
      _other -> false
    end
  end

  defp load_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} = post -> post_payload(post)
      _other -> nil
    end
  end

  defp list_posts(project_id) do
    Repo.all(from(post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at]))
    |> Enum.map(&post_payload/1)
  end

  defp load_post_by_slug(project_id, slug) do
    Repo.one(
      from(post in Post,
        where: post.project_id == ^project_id and post.slug == ^(string_or_nil(slug) || ""),
        limit: 1
      )
    )
    |> case do
      %Post{} = post -> post_payload(post)
      nil -> nil
    end
  end

  defp publish_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.publish_post(post_id) |> unwrap_result(&post_payload/1)
      _other -> nil
    end
  end

  defp discard_post(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.discard_post_changes(post_id) |> unwrap_result(&post_payload/1)
      _other -> nil
    end
  end

  defp filter_posts(project_id, filters) do
    project_id
    |> Search.search_posts("", normalize_search_filters(filters))
    |> unwrap_result(fn %{posts: posts} -> Enum.map(posts, &post_payload/1) end)
  end

  defp generate_unique_post_slug(project_id, title, exclude_post_id) do
    Posts.unique_slug_for_title(project_id, string_or_nil(title) || "", string_or_nil(exclude_post_id))
  end

  defp posts_by_status(project_id, status) do
    normalized_status = string_or_nil(status) || ""

    Repo.all(from(post in Post, where: post.project_id == ^project_id, order_by: [asc: post.created_at]))
    |> Enum.filter(&(to_string(&1.status) == normalized_status))
    |> Enum.map(&post_payload/1)
  end

  defp post_counts_by_year_month(project_id) do
    Posts.post_counts_by_year_month(project_id)
    |> sanitize()
  end

  defp post_dashboard_stats(project_id) do
    Posts.dashboard_stats(project_id)
    |> sanitize()
  end

  defp linked_posts_for(project_id, post_id, direction) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} -> linked_posts(id, direction)
      _other -> []
    end
  end

  defp preview_url(project_id, post_id, options) do
    case fetch_post(project_id, post_id) do
      %Post{} = post ->
        with {:ok, server} <- Preview.start_preview(project_id) do
          base_url = "http://#{server.host}:#{server.port}"
          canonical_path = canonical_preview_path(post.created_at, post.slug)
          options = normalize_map(options)
          language = options |> Map.get("lang") |> string_or_nil() |> blank_to_nil()

          query =
            %{}
            |> maybe_put_query("draft", truthy?(Map.get(options, "draft")) && "true")
            |> maybe_put_query("post_id", truthy?(Map.get(options, "draft")) && post.id)
            |> maybe_put_query("lang", language)

          if map_size(query) == 0 do
            base_url <> canonical_path
          else
            base_url <> canonical_path <> "?" <> URI.encode_query(query)
          end
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp post_slug_available?(project_id, slug, exclude_post_id) do
    Posts.slug_available(project_id, string_or_nil(slug) || "", string_or_nil(exclude_post_id))
  end

  defp publish_post_translation(project_id, post_id, language) do
    case fetch_post(project_id, post_id) do
      %Post{} -> Posts.publish_post_translation(post_id, string_or_nil(language) || "") |> unwrap_result()
      _other -> nil
    end
  end

  defp rebuild_post_links(project_id) do
    case Posts.rebuild_post_links(project_id) do
      :ok -> true
      _other -> false
    end
  end

  defp rebuild_posts_from_files(project_id) do
    project_id
    |> Posts.rebuild_posts_from_files()
    |> unwrap_result(fn posts -> Enum.map(posts, &post_payload/1) end)
  end

  defp reindex_project_search(project_id) do
    case Search.reindex_project(project_id) do
      :ok -> true
      _other -> false
    end
  end

  defp search_posts(project_id, query) do
    project_id
    |> Search.search_posts(string_or_nil(query) || "")
    |> unwrap_result(fn %{posts: posts} -> Enum.map(posts, &post_payload/1) end)
  end

  defp post_tags(project_id), do: names_with_counts(project_id, :tags) |> Enum.map(& &1["name"])
  defp post_tags_with_counts(project_id), do: names_with_counts(project_id, :tags)
  defp post_categories(project_id), do: names_with_counts(project_id, :categories) |> Enum.map(& &1["name"])
  defp post_categories_with_counts(project_id), do: names_with_counts(project_id, :categories)

  defp list_post_translations(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} ->
        id
        |> Posts.list_post_translations()
        |> unwrap_result(fn translations -> Enum.map(translations, &sanitize/1) end)

      _other ->
        []
    end
  end

  defp load_post_translation(project_id, post_id, language) do
    case fetch_post(project_id, post_id) do
      %Post{id: id} ->
        Repo.one(
          from(translation in PostTranslation,
            where:
              translation.translation_for == ^id and
                translation.language == ^(string_or_nil(language) || ""),
            limit: 1
          )
        )
        |> sanitize_nilable()

      _other ->
        nil
    end
  end

  defp has_published_post_version(project_id, post_id) do
    case fetch_post(project_id, post_id) do
      %Post{status: :published} -> true
      %Post{published_at: published_at, file_path: file_path} -> not is_nil(published_at) or file_path not in [nil, ""]
      _other -> false
    end
  end

  defp import_media(project_id, attrs) do
    attrs
    |> normalize_map()
    |> normalize_media_attrs()
    |> Map.put("project_id", project_id)
    |> Media.import_media()
    |> unwrap_result()
  end

  defp update_media(project_id, media_id, attrs) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} -> Media.update_media(media_id, attrs |> normalize_map() |> normalize_media_attrs()) |> unwrap_result()
      _other -> nil
    end
  end

  defp delete_media(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} -> boolean_result(Media.delete_media(media_id))
      _other -> false
    end
  end

  defp load_media(project_id, media_id) do
    fetch_media(project_id, media_id)
    |> sanitize_nilable()
  end

  defp list_media(project_id) do
    Repo.all(
      from(media in MediaRecord, where: media.project_id == ^project_id, order_by: [asc: media.created_at])
    )
    |> Enum.map(&sanitize/1)
  end

  defp load_media_translation(project_id, media_id, language) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{id: id} ->
        Repo.one(
          from(translation in MediaTranslation,
            where:
              translation.translation_for == ^id and
                translation.language == ^(string_or_nil(language) || ""),
            limit: 1
          )
        )
        |> sanitize_nilable()

      _other ->
        nil
    end
  end

  defp list_media_translations(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{id: id} ->
        Repo.all(
          from(translation in MediaTranslation,
            where: translation.translation_for == ^id,
            order_by: [asc: translation.language]
          )
        )
        |> Enum.map(&sanitize/1)

      _other ->
        []
    end
  end

  defp upsert_media_translation(project_id, media_id, language, attrs) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        Media.upsert_media_translation(media_id, string_or_nil(language) || "", normalize_media_translation_attrs(normalize_map(attrs)))
        |> unwrap_result()

      _other ->
        nil
    end
  end

  defp delete_media_translation(project_id, media_id, language) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        case Media.delete_media_translation(media_id, string_or_nil(language) || "") do
          {:ok, deleted?} -> deleted?
          {:error, _reason} -> false
        end

      _other ->
        false
    end
  end

  defp filter_media(project_id, filters) do
    filters = normalize_map(filters)

    list_media(project_id)
    |> Enum.filter(fn media -> media_matches_filters?(media, filters) end)
  end

  defp media_counts_by_year_month(project_id) do
    list_media(project_id)
    |> Enum.reduce(%{}, fn media, acc ->
      datetime = media_datetime(media)
      key = {datetime.year, datetime.month}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{year, month}, count} -> %{"year" => year, "month" => month, "count" => count} end)
    |> Enum.sort_by(fn row -> {-row["year"], -row["month"]} end)
  end

  defp media_file_path(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media -> Path.join(project_path(project_id), media.file_path)
      _other -> nil
    end
  end

  defp media_tags(project_id), do: media_tags_with_counts(project_id) |> Enum.map(& &1["tag"])

  defp media_tags_with_counts(project_id) do
    Repo.all(from(media in MediaRecord, where: media.project_id == ^project_id, order_by: [asc: media.created_at]))
    |> Enum.flat_map(&(&1.tags || []))
    |> Enum.reduce(%{}, fn tag, acc -> Map.update(acc, tag, 1, &(&1 + 1)) end)
    |> Enum.map(fn {tag, count} -> %{"tag" => tag, "count" => count} end)
    |> Enum.sort_by(fn row -> {-row["count"], String.downcase(row["tag"])} end)
  end

  defp media_thumbnail(project_id, media_id, size) do
    with %MediaRecord{} = media <- fetch_media(project_id, media_id),
         relative_path <- Media.thumbnail_paths(media)[thumbnail_size(size)],
         absolute_path <- Path.join(project_path(project_id), relative_path),
         true <- File.exists?(absolute_path),
         {:ok, binary} <- File.read(absolute_path) do
      "data:#{thumbnail_mime(absolute_path)};base64," <> Base.encode64(binary)
    else
      _other -> nil
    end
  end

  defp media_url(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media -> "/" <> String.trim_leading(media.file_path, "/")
      _other -> nil
    end
  end

  defp rebuild_media_from_files(project_id) do
    project_id
    |> Media.rebuild_media_from_files()
    |> unwrap_result(fn media -> Enum.map(media, &sanitize/1) end)
  end

  defp regenerate_missing_thumbnails(project_id) do
    Media.regenerate_missing_thumbnails(project_id)
    |> sanitize()
  end

  defp regenerate_media_thumbnails(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media ->
        case Media.regenerate_thumbnails(media.id) do
          {:ok, _media} ->
            Media.thumbnail_paths(media)
            |> Enum.map(fn {size, relative_path} -> {to_string(size), Path.join(project_path(project_id), relative_path)} end)
            |> Map.new()

          {:error, _reason} ->
            nil
        end

      _other ->
        nil
    end
  end

  defp replace_media_file(project_id, media_id, source_path) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        Media.replace_media_file(media_id, string_or_nil(source_path) || "")
        |> unwrap_result()

      _other ->
        nil
    end
  end

  defp search_media(project_id, query) do
    project_id
    |> Search.search_media(string_or_nil(query) || "")
    |> unwrap_result(fn %{media: media} -> Enum.map(media, &sanitize/1) end)
  end

  defp create_script(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Scripts.create_script()
    |> unwrap_result()
  end

  defp update_script(project_id, script_id, attrs) do
    case fetch_script(project_id, script_id) do
      %Script{} -> Scripts.update_script(script_id, normalize_map(attrs)) |> unwrap_result()
      _other -> nil
    end
  end

  defp delete_script(project_id, script_id) do
    case fetch_script(project_id, script_id) do
      %Script{} -> boolean_result(Scripts.delete_script(script_id))
      _other -> false
    end
  end

  defp load_script(project_id, script_id) do
    fetch_script(project_id, script_id)
    |> sanitize_nilable()
  end

  defp list_scripts(project_id) do
    Repo.all(
      from(script in Script, where: script.project_id == ^project_id, order_by: [asc: script.created_at])
    )
    |> Enum.map(&sanitize/1)
  end

  defp publish_script(project_id, script_id) do
    case fetch_script(project_id, script_id) do
      %Script{} -> Scripts.publish_script(script_id) |> unwrap_result()
      _other -> nil
    end
  end

  defp rebuild_scripts_from_files(project_id) do
    project_id
    |> Scripts.rebuild_scripts_from_files()
    |> unwrap_result()
  end

  defp create_template(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Templates.create_template()
    |> unwrap_result()
  end

  defp update_template(project_id, template_id, attrs) do
    case fetch_template(project_id, template_id) do
      %Template{} -> Templates.update_template(template_id, normalize_map(attrs)) |> unwrap_result()
      _other -> nil
    end
  end

  defp delete_template(project_id, template_id) do
    case fetch_template(project_id, template_id) do
      %Template{} -> boolean_result(Templates.delete_template(template_id))
      _other -> false
    end
  end

  defp load_template(project_id, template_id) do
    fetch_template(project_id, template_id)
    |> sanitize_nilable()
  end

  defp list_templates(project_id) do
    Repo.all(
      from(template in Template, where: template.project_id == ^project_id, order_by: [asc: template.created_at])
    )
    |> Enum.map(&sanitize/1)
  end

  defp publish_template(project_id, template_id) do
    case fetch_template(project_id, template_id) do
      %Template{} -> Templates.publish_template(template_id) |> unwrap_result()
      _other -> nil
    end
  end

  defp list_enabled_templates(project_id, kind) do
    Repo.all(
      from(template in Template,
        where:
          template.project_id == ^project_id and template.enabled == true and
            template.kind == ^string_or_nil(kind),
        order_by: [asc: template.created_at]
      )
    )
    |> Enum.map(&sanitize/1)
  end

  defp rebuild_templates_from_files(project_id) do
    project_id
    |> Templates.rebuild_templates_from_files()
    |> unwrap_result()
  end

  defp validate_template_source(source) do
    source
    |> string_or_nil()
    |> Kernel.||("")
    |> MCP.validate_template()
    |> unwrap_result()
  end

  defp create_tag(project_id, attrs) do
    attrs
    |> normalize_map()
    |> Map.put("project_id", project_id)
    |> Tags.create_tag()
    |> unwrap_result()
  end

  defp update_tag(project_id, tag_id, attrs) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> Tags.update_tag(tag_id, normalize_map(attrs)) |> unwrap_result()
      _other -> nil
    end
  end

  defp delete_tag(project_id, tag_id) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> boolean_result(Tags.delete_tag(tag_id))
      _other -> false
    end
  end

  defp load_tag(project_id, tag_id) do
    fetch_tag(project_id, tag_id)
    |> sanitize_nilable()
  end

  defp list_tags(project_id) do
    Tags.list_tags(project_id)
    |> Enum.map(&sanitize/1)
  end

  defp tags_with_counts(project_id) do
    counts_by_name =
      names_with_counts(project_id, :tags)
      |> Map.new(fn entry -> {entry["name"], entry["count"]} end)

    list_tags(project_id)
    |> Enum.map(fn tag -> Map.put(tag, "count", Map.get(counts_by_name, tag["name"], 0)) end)
  end

  defp tag_post_ids(project_id, tag_id) do
    case fetch_tag(project_id, tag_id) do
      %Tag{name: tag_name} ->
        Repo.all(
          from(post in Post,
            where: post.project_id == ^project_id,
            order_by: [asc: post.created_at]
          )
        )
        |> Enum.filter(&(tag_name in (&1.tags || [])))
        |> Enum.map(& &1.id)

      _other ->
        []
    end
  end

  defp load_tag_by_name(project_id, tag_name) do
    Repo.one(
      from(tag in Tag,
        where:
          tag.project_id == ^project_id and
            fragment("lower(?)", tag.name) == ^String.downcase(string_or_nil(tag_name) || ""),
        limit: 1
      )
    )
    |> sanitize_nilable()
  end

  defp rename_tag(project_id, tag_id, new_name) do
    case fetch_tag(project_id, tag_id) do
      %Tag{} -> Tags.rename_tag(tag_id, string_or_nil(new_name) || "") |> unwrap_result()
      _other -> nil
    end
  end

  defp merge_tags(project_id, source_tag_ids, target_tag_id) do
    case fetch_tag(project_id, target_tag_id) do
      %Tag{} -> atom_result(Tags.merge_tags(normalize_string_list(source_tag_ids), target_tag_id), :merged)
      _other -> false
    end
  end

  defp sync_tags_from_posts(project_id) do
    Tags.sync_tags_from_posts(project_id)
    |> unwrap_result()
  end

  defp load_task(task_id) do
    case string_or_nil(task_id) do
      nil -> nil
      id -> Tasks.get_task(id) |> sanitize_nilable()
    end
  end

  defp cancel_task(task_id) do
    case string_or_nil(task_id) do
      nil -> false
      id -> match?(:ok, Tasks.cancel_task(id))
    end
  end

  defp list_all_tasks do
    Tasks.list_tasks()
    |> Enum.map(&sanitize/1)
  end

  defp list_running_tasks do
    Tasks.list_running_tasks()
    |> Enum.map(&sanitize/1)
  end

  defp clear_completed_tasks do
    match?(:ok, Tasks.clear_completed())
  end

  defp data_paths(project_id) do
    database_path = Repo.config()[:database]
    project_dir = project_path(project_id)

    %{
      database: database_path,
      project: project_dir,
      posts: Path.join(project_dir, "posts"),
      media: Path.join(project_dir, "media")
    }
  end

  defp project_path(project_id) do
    project_id
    |> Projects.get_project()
    |> Projects.project_data_dir()
  end

  defp read_project_metadata(folder_path) do
    case project_for_folder(folder_path) do
      nil -> read_project_metadata_file(folder_path)
      project -> load_metadata(project.id)
    end
  end

  defp copy_to_clipboard(text, opts) do
    case Keyword.get(opts, :copy_to_clipboard) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(text) || "")
      _other -> do_copy_to_clipboard(text)
    end
  end

  defp do_copy_to_clipboard(text) do
    if @mix_env == :test do
      true
    else
      command = string_or_nil(text) || ""

      case :os.type() do
        {:unix, :darwin} -> match?({_output, 0}, System.cmd("pbcopy", [], input: command, stderr_to_stdout: true))
        {:unix, _other} -> match?({_output, 0}, System.cmd("xclip", ["-selection", "clipboard"], input: command, stderr_to_stdout: true))
        {:win32, _other} -> match?({_output, 0}, System.cmd("cmd", ["/c", "clip"], input: command, stderr_to_stdout: true))
      end
    end
  rescue
    _error -> false
  end

  defp blogmark_bookmarklet do
    "javascript:(()=>{const t=encodeURIComponent(document.title||'');const u=encodeURIComponent(location.href||'');location.href='bds://new-post?title='+t+'&url='+u;})();"
  end

  defp title_bar_metrics(opts) do
    case Keyword.get(opts, :title_bar_metrics) do
      callback when is_function(callback, 0) -> callback.()
      _other -> do_title_bar_metrics()
    end
  end

  defp do_title_bar_metrics do
    case :os.type() do
      {:unix, :darwin} -> %{macos_left_inset: 72}
      _other -> nil
    end
  end

  defp notify_renderer_ready(opts) do
    case Keyword.get(opts, :notify_renderer_ready) do
      callback when is_function(callback, 0) -> callback.()
      _other -> true
    end
  end

  defp open_folder(folder_path, opts) do
    case Keyword.get(opts, :open_folder) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(folder_path) || "")
      _other -> do_open_folder(folder_path)
    end
  end

  defp do_open_folder(folder_path) do
    if @mix_env == :test do
      ""
    else
      case open_system_path(string_or_nil(folder_path) || "") do
        :ok -> ""
        {:error, reason} -> inspect(reason)
      end
    end
  end

  defp select_folder(title, opts) do
    case Keyword.get(opts, :select_folder) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(title) || "Select Folder")
      _other -> do_select_folder(title)
    end
  end

  defp do_select_folder(title) do
    if @mix_env == :test do
      nil
    else
      case FolderPicker.choose_directory(string_or_nil(title) || "Select Folder") do
        {:ok, path} -> path
        :cancel -> nil
        {:error, _reason} -> nil
      end
    end
  end

  defp set_preview_post_target(post_id) do
    :persistent_term.put({__MODULE__, :preview_post_target}, string_or_nil(post_id))
    true
  end

  defp show_item_in_folder(item_path, opts) do
    callback = Keyword.get(opts, :show_item_in_folder)

    cond do
      is_function(callback, 1) -> callback.(string_or_nil(item_path) || "")
      @mix_env == :test -> :ok
      true -> _ = reveal_system_path(string_or_nil(item_path) || "")
    end

    nil
  end

  defp trigger_menu_action(action, opts) do
    callback = Keyword.get(opts, :trigger_menu_action)

    cond do
      is_function(callback, 1) -> callback.(string_or_nil(action) || "")
      @mix_env == :test -> :ok
      true -> _ = MenuBar.handle_event(string_or_nil(action) || "", nil)
    end

    nil
  rescue
    _error -> nil
  end

  defp sync_available?, do: not is_nil(System.find_executable("git"))

  defp repo_state(project_id, opts) do
    project_id
    |> Git.repository(git_opts(opts))
    |> unwrap_result()
  end

  defp repo_status(project_id, opts) do
    project_id
    |> Git.status(git_opts(opts))
    |> unwrap_result()
  end

  defp repo_history(project_id, opts) do
    case Git.repository(project_id, git_opts(opts)) do
      {:ok, %{current_branch: branch}} when is_binary(branch) and branch != "" ->
        Git.history(project_id, branch, git_opts(opts))
        |> unwrap_result()

      _other ->
        %{"commits" => []}
    end
  end

  defp repo_fetch(project_id, opts), do: project_id |> Git.fetch(git_opts(opts)) |> unwrap_result()
  defp repo_pull(project_id, opts), do: project_id |> Git.pull(git_opts(opts)) |> unwrap_result()
  defp repo_push(project_id, opts), do: project_id |> Git.push(git_opts(opts)) |> unwrap_result()

  defp repo_commit_all(project_id, message, opts) do
    project_id
    |> Git.commit_all(string_or_nil(message) || "", git_opts(opts))
    |> unwrap_result()
  end

  defp upload_site(project_id, credentials, opts) do
    project_id
    |> Publishing.upload_site(normalize_map(credentials), publishing_opts(opts))
    |> unwrap_result()
  end

  defp detect_post_language(title, content, opts) do
    text = Enum.join([string_or_nil(title) || "", string_or_nil(content) || ""], "\n\n")

    case AI.detect_language(text, ai_opts(opts)) do
      {:ok, %{language_code: language_code}} -> %{"success" => true, "language" => language_code}
      {:error, reason} -> %{"success" => false, "error" => inspect(reason)}
    end
  end

  defp analyze_post(post_id, opts) do
    post_id
    |> string_or_nil()
    |> AI.analyze_post(ai_opts(opts))
    |> unwrap_result()
  end

  defp translate_post(post_id, language, opts) do
    post_id = string_or_nil(post_id)
    language = string_or_nil(language) || ""

    with {:ok, translation} <- AI.translate_post(post_id, language, ai_opts(opts)),
         {:ok, saved_translation} <-
           Posts.upsert_post_translation(post_id, language, %{
             title: translation.title,
             excerpt: translation.excerpt,
             content: translation.content
           }) do
      sanitize(saved_translation)
    else
      _other -> nil
    end
  end

  defp analyze_media_image(media_id, opts) do
    case AI.analyze_image(string_or_nil(media_id), ai_opts(opts)) do
      {:ok, result} -> sanitize(result)
      {:error, _reason} -> nil
    end
  end

  defp detect_media_language(title, alt, caption, opts) do
    text = Enum.join([string_or_nil(title) || "", string_or_nil(alt) || "", string_or_nil(caption) || ""], "\n")

    case AI.detect_language(text, ai_opts(opts)) do
      {:ok, %{language_code: language_code}} -> %{"success" => true, "language" => language_code}
      {:error, reason} -> %{"success" => false, "error" => inspect(reason)}
    end
  end

  defp translate_media_metadata(media_id, language, opts) do
    media_id = string_or_nil(media_id)
    language = string_or_nil(language) || ""

    with {:ok, translation} <- AI.translate_media(media_id, language, ai_opts(opts)),
         {:ok, saved_translation} <-
           Media.upsert_media_translation(media_id, language, %{
             title: translation.title,
             alt: translation.alt,
             caption: translation.caption
           }) do
      sanitize(saved_translation)
    else
      _other -> nil
    end
  end

  defp embedding_progress(project_id), do: project_id |> Embeddings.get_indexing_progress() |> unwrap_result()

  defp find_similar(post_id, limit) do
    post_id
    |> string_or_nil()
    |> Embeddings.find_similar(integer_or_default(limit, 5))
    |> unwrap_result()
  end

  defp compute_similarities(post_id, target_ids) do
    post_id
    |> string_or_nil()
    |> Embeddings.compute_similarities(normalize_string_list(target_ids))
    |> unwrap_result()
  end

  defp suggest_tags(post_id, exclude_tags) do
    post_id
    |> string_or_nil()
    |> Embeddings.suggest_tags(normalize_string_list(exclude_tags))
    |> unwrap_result()
  end

  defp find_duplicates(project_id), do: project_id |> Embeddings.find_duplicates() |> unwrap_result()
  defp dismiss_pair(post_id_a, post_id_b), do: atom_result(Embeddings.dismiss_duplicate_pair(string_or_nil(post_id_a) || "", string_or_nil(post_id_b) || ""), :ok)
  defp index_unindexed_posts(project_id), do: project_id |> Embeddings.index_unindexed() |> unwrap_result()

  defp fetch_post(project_id, post_id) do
    Repo.one(
      from(post in Post,
        where: post.project_id == ^project_id and post.id == ^(string_or_nil(post_id) || ""),
        limit: 1
      )
    )
  end

  defp fetch_media(project_id, media_id) do
    Repo.one(
      from(media in MediaRecord,
        where: media.project_id == ^project_id and media.id == ^(string_or_nil(media_id) || ""),
        limit: 1
      )
    )
  end

  defp fetch_script(project_id, script_id) do
    Repo.one(
      from(script in Script,
        where: script.project_id == ^project_id and script.id == ^(string_or_nil(script_id) || ""),
        limit: 1
      )
    )
  end

  defp fetch_template(project_id, template_id) do
    Repo.one(
      from(template in Template,
        where: template.project_id == ^project_id and template.id == ^(string_or_nil(template_id) || ""),
        limit: 1
      )
    )
  end

  defp fetch_tag(project_id, tag_id) do
    Repo.one(
      from(tag in Tag,
        where: tag.project_id == ^project_id and tag.id == ^(string_or_nil(tag_id) || ""),
        limit: 1
      )
    )
  end

  defp zero_or_one_arg(callback) when is_function(callback, 1) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)
      value = callback.(normalize_input(decoded_args))
      :luerl.encode_list([sanitize(value)], state)
    end
  end

  defp one_arg(callback) when is_function(callback, 1) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first | _rest] -> callback.(normalize_input(first))
          [] -> callback.(nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end

  defp two_arg(callback) when is_function(callback, 2) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first, second | _rest] -> callback.(normalize_input(first), normalize_input(second))
          [first] -> callback.(normalize_input(first), nil)
          [] -> callback.(nil, nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end

  defp three_arg(callback) when is_function(callback, 3) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first, second, third | _rest] -> callback.(normalize_input(first), normalize_input(second), normalize_input(third))
          [first, second] -> callback.(normalize_input(first), normalize_input(second), nil)
          [first] -> callback.(normalize_input(first), nil, nil)
          [] -> callback.(nil, nil, nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end

  defp post_payload(%Post{} = post) do
    post
    |> sanitize()
    |> Map.put("backlinks", linked_posts(post.id, :incoming))
    |> Map.put("links_to", linked_posts(post.id, :outgoing))
  end

  defp linked_posts(post_id, :incoming) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&load_linked_post(&1.source_post_id))
    |> Enum.reject(&is_nil/1)
  end

  defp linked_posts(post_id, :outgoing) do
    PostLinks.list_outgoing_links(post_id)
    |> Enum.map(&load_linked_post(&1.target_post_id))
    |> Enum.reject(&is_nil/1)
  end

  defp load_linked_post(post_id) do
    case Repo.get(Post, post_id) do
      %Post{} = post -> %{"id" => post.id, "title" => post.title, "slug" => post.slug}
      nil -> nil
    end
  end

  defp unwrap_result(result, transform \\ &sanitize/1)

  defp unwrap_result({:ok, value}, transform), do: transform.(value)
  defp unwrap_result({:error, _reason}, _transform), do: nil

  defp boolean_result({:ok, _value}), do: true
  defp boolean_result({:error, _reason}), do: false

  defp atom_result({:ok, value}, expected_value), do: value == expected_value
  defp atom_result(_result, _expected_value), do: false

  defp sanitize_nilable(nil), do: nil
  defp sanitize_nilable(value), do: sanitize(value)

  defp normalize_map(value) when is_map(value) do
    case normalize_input(value) do
      normalized when is_map(normalized) -> normalized
      _other -> %{}
    end
  end
  defp normalize_map(value) when is_list(value) do
    if Enum.all?(value, &match?({key, _value} when is_binary(key) or is_atom(key), &1)) do
      Map.new(value, fn {key, entry_value} -> {to_string(key), normalize_input(entry_value)} end)
    else
      %{}
    end
  end
  defp normalize_map(_value), do: %{}

  defp normalize_string_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  defp normalize_string_list(value) when is_map(value) do
    value
    |> normalize_input()
    |> case do
      normalized when is_list(normalized) -> Enum.map(normalized, &to_string/1)
      _other -> []
    end
  end

  defp normalize_string_list(_value), do: []

  defp integer_or_default(value, _default) when is_integer(value), do: value
  defp integer_or_default(value, _default) when is_float(value), do: trunc(value)
  defp integer_or_default(_value, default), do: default

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp string_or_nil(value) when is_number(value), do: to_string(value)
  defp string_or_nil(_value), do: nil

  defp normalize_input(%_struct{} = struct), do: struct |> Map.from_struct() |> normalize_input()

  defp normalize_input(map) when is_map(map) do
    normalized =
      Map.new(map, fn {key, value} -> {normalize_input_key(key), normalize_input(value)} end)

    if numeric_sequence_map?(normalized) do
      normalized
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {_key, value} -> value end)
    else
      normalized
    end
  end

  defp normalize_input(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _value} when is_integer(key) or is_float(key) or is_binary(key) or is_atom(key), &1)) do
      normalized =
        Map.new(list, fn {key, value} -> {normalize_input_key(key), normalize_input(value)} end)

      if numeric_sequence_map?(normalized) do
        normalized
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map(fn {_key, value} -> value end)
      else
        normalized
      end
    else
      Enum.map(list, &normalize_input/1)
    end
  end
  defp normalize_input(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_input(value), do: value

  defp git_opts(opts) do
    case Keyword.get(opts, :git_runner) do
      nil -> []
      runner -> [runner: runner]
    end
  end

  defp publishing_opts(opts) do
    case Keyword.get(opts, :publishing_uploader) do
      nil -> []
      uploader -> [uploader: uploader]
    end
  end

  defp ai_opts(opts) do
    []
    |> maybe_put_opt(:runtime, Keyword.get(opts, :ai_runtime))
    |> maybe_put_opt(:secret_backend, Keyword.get(opts, :ai_secret_backend))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp project_for_folder(folder_path) do
    normalized = string_or_nil(folder_path)

    Projects.list_projects()
    |> Enum.find(fn project -> Projects.project_data_dir(project) == normalized end)
  end

  defp read_project_metadata_file(folder_path) do
    path = Path.join([string_or_nil(folder_path) || "", "meta", "project.json"])

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} when is_map(decoded) -> sanitize(decoded)
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :post, :project, :media, :translations])
    |> sanitize()
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(value) when is_boolean(value), do: value
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value), do: value

  defp normalize_input_key(key) when is_integer(key), do: key
  defp normalize_input_key(key) when is_float(key) and trunc(key) == key, do: trunc(key)
  defp normalize_input_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {integer, ""} -> integer
      _other -> key
    end
  end
  defp normalize_input_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_input_key(key), do: key

  defp numeric_sequence_map?(map) when map == %{}, do: false

  defp numeric_sequence_map?(map) do
    keys = Map.keys(map)

    Enum.all?(keys, &is_integer/1) and Enum.sort(keys) == Enum.to_list(1..length(keys))
  end

  defp normalize_media_attrs(attrs) do
    attrs
    |> maybe_put_normalized_list("tags")
  end

  defp normalize_media_translation_attrs(attrs) do
    attrs
    |> Map.take(["title", "alt", "caption"])
  end

  defp maybe_put_normalized_list(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, normalize_string_list(value))
      :error -> attrs
    end
  end

  defp names_with_counts(project_id, field) when field in [:tags, :categories] do
    Repo.all(
      from(post in Post,
        where: post.project_id == ^project_id,
        order_by: [asc: post.created_at]
      )
    )
    |> Enum.flat_map(&(Map.get(&1, field) || []))
    |> Enum.reduce(%{}, fn name, acc -> Map.update(acc, name, 1, &(&1 + 1)) end)
    |> Enum.map(fn {name, count} -> %{"name" => name, "count" => count} end)
    |> Enum.sort_by(&{String.downcase(&1["name"]), &1["count"]})
  end

  defp media_matches_filters?(media, filters) do
    created_at = media_datetime(media)
    tags = Map.get(media, "tags", [])
    language = Map.get(media, "language")

    matches_year = compare_optional(Map.get(filters, "year"), fn year -> created_at.year == integer_or_default(year, created_at.year) end)
    matches_month = compare_optional(Map.get(filters, "month"), fn month -> created_at.month == integer_or_default(month, created_at.month) end)
    matches_language = compare_optional(blank_to_nil(Map.get(filters, "language")), fn value -> language == value end)
    matches_tags = compare_optional(Map.get(filters, "tags"), fn required_tags -> Enum.all?(normalize_string_list(required_tags), &(&1 in tags)) end)
    matches_from = compare_optional(parse_datetime(Map.get(filters, "from") || Map.get(filters, "start_date")), fn from_dt -> DateTime.compare(created_at, from_dt) != :lt end)
    matches_to = compare_optional(parse_datetime(Map.get(filters, "to") || Map.get(filters, "end_date")), fn to_dt -> DateTime.compare(created_at, to_dt) != :gt end)

    matches_year and matches_month and matches_language and matches_tags and matches_from and matches_to
  end

  defp media_datetime(media) do
    media
    |> Map.get("created_at")
    |> case do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _other -> DateTime.utc_now()
        end

      value when is_integer(value) -> DateTime.from_unix!(value, :millisecond)
      _other -> DateTime.utc_now()
    end
  end

  defp canonical_preview_path(created_at_ms, slug) do
    datetime = DateTime.from_unix!(created_at_ms, :millisecond)
    "/#{datetime.year}/#{pad2(datetime.month)}/#{pad2(datetime.day)}/#{string_or_nil(slug) || ""}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp truthy?(value), do: value in [true, "true", 1, 1.0, "1"]

  defp maybe_put_query(query, _key, false), do: query
  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end
  defp blank_to_nil(value), do: value

  defp thumbnail_size(size) do
    case blank_to_nil(size) do
      "medium" -> :medium
      "large" -> :large
      "ai" -> :ai
      _other -> :small
    end
  end

  defp thumbnail_mime(path) do
    case Path.extname(path) do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _other -> "image/webp"
    end
  end

  defp compare_optional(nil, _fun), do: true
  defp compare_optional(value, fun) when is_function(fun, 1), do: fun.(value)

  defp normalize_search_filters(filters) do
    filters
    |> normalize_map()
    |> Enum.into(%{}, fn {key, value} ->
      normalized_key =
        case key do
          "start_date" -> "from"
          "end_date" -> "to"
          other -> other
        end

      {normalized_key, value}
    end)
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end
  defp parse_datetime(_value), do: nil

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

  defp reveal_system_path(path) do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", ["-R", path]}
        {:unix, _other} -> {"xdg-open", [Path.dirname(path)]}
        {:win32, _other} -> {"explorer", ["/select,", path]}
      end

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end
end
