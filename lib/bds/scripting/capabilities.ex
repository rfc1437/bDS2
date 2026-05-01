defmodule BDS.Scripting.Capabilities do
  @moduledoc false

  alias BDS.I18n
  alias BDS.Tasks
  alias BDS.Scripting.Capabilities.AppShell
  alias BDS.Scripting.Capabilities.Bridges
  alias BDS.Scripting.Capabilities.Crud, as: CrudCaps
  alias BDS.Scripting.Capabilities.Media, as: MediaCaps
  alias BDS.Scripting.Capabilities.Posts, as: PostsCaps
  alias BDS.Scripting.Capabilities.Projects, as: ProjectsCaps
  alias BDS.Scripting.Capabilities.Util

  import Util
  import AppShell
  import Bridges
  import CrudCaps
  import MediaCaps
  import PostsCaps
  import ProjectsCaps

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
        delete_with_data:
          one_arg(fn project_id_to_delete -> delete_project_with_data(project_id_to_delete) end),
        get: one_arg(fn project_id_to_load -> load_project(project_id_to_load) end),
        get_all: zero_or_one_arg(fn _args -> list_projects() end),
        get_active: zero_or_one_arg(fn _args -> load_project(project_id) end),
        set_active:
          one_arg(fn project_id_to_activate -> set_active_project(project_id_to_activate) end),
        update:
          two_arg(fn project_id_to_update, attrs ->
            update_project(project_id_to_update, attrs)
          end)
      },
      meta: %{
        get_project_metadata: zero_or_one_arg(fn _args -> load_metadata(project_id) end),
        update_project_metadata:
          one_arg(fn attrs -> update_project_metadata(project_id, attrs) end),
        add_category: one_arg(fn name -> add_category(project_id, name) end),
        remove_category: one_arg(fn name -> remove_category(project_id, name) end),
        add_tag: one_arg(fn name -> add_meta_tag(project_id, name) end),
        get_categories: zero_or_one_arg(fn _args -> metadata_categories(project_id) end),
        set_project_metadata: one_arg(fn attrs -> update_project_metadata(project_id, attrs) end),
        get_publishing_preferences:
          zero_or_one_arg(fn _args -> publishing_preferences(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> metadata_tags(project_id) end),
        remove_tag: one_arg(fn name -> remove_meta_tag(project_id, name) end),
        set_publishing_preferences:
          one_arg(fn prefs -> set_publishing_preferences(project_id, prefs) end),
        clear_publishing_preferences:
          zero_or_one_arg(fn _args -> clear_publishing_preferences(project_id) end),
        sync_on_startup: zero_or_one_arg(fn _args -> sync_meta_on_startup(project_id) end)
      },
      posts: %{
        create: one_arg(fn attrs -> create_post(project_id, attrs) end),
        discard: one_arg(fn post_id -> discard_post(project_id, post_id) end),
        filter: one_arg(fn filters -> filter_posts(project_id, filters) end),
        generate_unique_slug:
          two_arg(fn title, exclude_post_id ->
            generate_unique_post_slug(project_id, title, exclude_post_id)
          end),
        get_by_status: one_arg(fn status -> posts_by_status(project_id, status) end),
        get_by_year_month: zero_or_one_arg(fn _args -> post_counts_by_year_month(project_id) end),
        get_dashboard_stats: zero_or_one_arg(fn _args -> post_dashboard_stats(project_id) end),
        get_linked_by:
          one_arg(fn post_id -> linked_posts_for(project_id, post_id, :incoming) end),
        get_links_to: one_arg(fn post_id -> linked_posts_for(project_id, post_id, :outgoing) end),
        get_preview_url:
          two_arg(fn post_id, options -> preview_url(project_id, post_id, options) end),
        update: two_arg(fn post_id, attrs -> update_post(project_id, post_id, attrs) end),
        delete: one_arg(fn post_id -> delete_post(project_id, post_id) end),
        get: one_arg(fn post_id -> load_post(project_id, post_id) end),
        get_all: zero_or_one_arg(fn _args -> list_posts(project_id) end),
        get_by_slug: one_arg(fn slug -> load_post_by_slug(project_id, slug) end),
        get_categories: zero_or_one_arg(fn _args -> post_categories(project_id) end),
        get_categories_with_counts:
          zero_or_one_arg(fn _args -> post_categories_with_counts(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> post_tags(project_id) end),
        get_tags_with_counts: zero_or_one_arg(fn _args -> post_tags_with_counts(project_id) end),
        get_translation:
          two_arg(fn post_id, language ->
            load_post_translation(project_id, post_id, language)
          end),
        get_translations: one_arg(fn post_id -> list_post_translations(project_id, post_id) end),
        has_published_version:
          one_arg(fn post_id -> has_published_post_version(project_id, post_id) end),
        is_slug_available:
          two_arg(fn slug, exclude_post_id ->
            post_slug_available?(project_id, slug, exclude_post_id)
          end),
        publish: one_arg(fn post_id -> publish_post(project_id, post_id) end),
        publish_translation:
          two_arg(fn post_id, language ->
            publish_post_translation(project_id, post_id, language)
          end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_posts_from_files(project_id) end),
        rebuild_links: zero_or_one_arg(fn _args -> rebuild_post_links(project_id) end),
        reindex_text: zero_or_one_arg(fn _args -> reindex_project_search(project_id) end),
        search: one_arg(fn query -> search_posts(project_id, query) end)
      },
      media: %{
        delete_translation:
          two_arg(fn media_id, language ->
            delete_media_translation(project_id, media_id, language)
          end),
        filter: one_arg(fn filters -> filter_media(project_id, filters) end),
        import: one_arg(fn attrs -> import_media(project_id, attrs) end),
        get_by_year_month:
          zero_or_one_arg(fn _args -> media_counts_by_year_month(project_id) end),
        get_file_path: one_arg(fn media_id -> media_file_path(project_id, media_id) end),
        update: two_arg(fn media_id, attrs -> update_media(project_id, media_id, attrs) end),
        delete: one_arg(fn media_id -> delete_media(project_id, media_id) end),
        get: one_arg(fn media_id -> load_media(project_id, media_id) end),
        get_all: zero_or_one_arg(fn _args -> list_media(project_id) end),
        get_tags: zero_or_one_arg(fn _args -> media_tags(project_id) end),
        get_tags_with_counts: zero_or_one_arg(fn _args -> media_tags_with_counts(project_id) end),
        get_thumbnail:
          two_arg(fn media_id, size -> media_thumbnail(project_id, media_id, size) end),
        get_translation:
          two_arg(fn media_id, language ->
            load_media_translation(project_id, media_id, language)
          end),
        get_translations:
          one_arg(fn media_id -> list_media_translations(project_id, media_id) end),
        get_url: one_arg(fn media_id -> media_url(project_id, media_id) end),
        rebuild_from_files: zero_or_one_arg(fn _args -> rebuild_media_from_files(project_id) end),
        regenerate_missing_thumbnails:
          zero_or_one_arg(fn _args -> regenerate_missing_thumbnails(project_id) end),
        regenerate_thumbnails:
          one_arg(fn media_id -> regenerate_media_thumbnails(project_id, media_id) end),
        reindex_text: zero_or_one_arg(fn _args -> reindex_project_search(project_id) end),
        replace_file:
          two_arg(fn media_id, source_path ->
            replace_media_file(project_id, media_id, source_path)
          end),
        search: one_arg(fn query -> search_media(project_id, query) end),
        upsert_translation:
          three_arg(fn media_id, language, attrs ->
            upsert_media_translation(project_id, media_id, language, attrs)
          end)
      },
      scripts: %{
        create: one_arg(fn attrs -> create_script(project_id, attrs) end),
        update: two_arg(fn script_id, attrs -> update_script(project_id, script_id, attrs) end),
        delete: one_arg(fn script_id -> delete_script(project_id, script_id) end),
        get: one_arg(fn script_id -> load_script(project_id, script_id) end),
        get_all: zero_or_one_arg(fn _args -> list_scripts(project_id) end),
        publish: one_arg(fn script_id -> publish_script(project_id, script_id) end),
        rebuild_from_files:
          zero_or_one_arg(fn _args -> rebuild_scripts_from_files(project_id) end)
      },
      templates: %{
        create: one_arg(fn attrs -> create_template(project_id, attrs) end),
        update:
          two_arg(fn template_id, attrs -> update_template(project_id, template_id, attrs) end),
        delete: one_arg(fn template_id -> delete_template(project_id, template_id) end),
        get: one_arg(fn template_id -> load_template(project_id, template_id) end),
        get_all: zero_or_one_arg(fn _args -> list_templates(project_id) end),
        publish: one_arg(fn template_id -> publish_template(project_id, template_id) end),
        get_enabled_by_kind: one_arg(fn kind -> list_enabled_templates(project_id, kind) end),
        rebuild_from_files:
          zero_or_one_arg(fn _args -> rebuild_templates_from_files(project_id) end),
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
        merge:
          two_arg(fn source_tag_ids, target_tag_id ->
            merge_tags(project_id, source_tag_ids, target_tag_id)
          end),
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
        detect_post_language:
          two_arg(fn title, content -> detect_post_language(title, content, opts) end),
        analyze_post: one_arg(fn post_id -> analyze_post(post_id, opts) end),
        translate_post:
          two_arg(fn post_id, language -> translate_post(post_id, language, opts) end),
        analyze_media_image: one_arg(fn media_id -> analyze_media_image(media_id, opts) end),
        detect_media_language:
          three_arg(fn title, alt, caption ->
            detect_media_language(title, alt, caption, opts)
          end),
        translate_media_metadata:
          two_arg(fn media_id, language -> translate_media_metadata(media_id, language, opts) end)
      },
      embeddings: %{
        get_progress: zero_or_one_arg(fn _args -> embedding_progress(project_id) end),
        find_similar: two_arg(fn post_id, limit -> find_similar(post_id, limit) end),
        compute_similarities:
          two_arg(fn post_id, target_ids -> compute_similarities(post_id, target_ids) end),
        suggest_tags:
          two_arg(fn post_id, exclude_tags -> suggest_tags(post_id, exclude_tags) end),
        find_duplicates: zero_or_one_arg(fn _args -> find_duplicates(project_id) end),
        dismiss_pair: two_arg(fn post_id_a, post_id_b -> dismiss_pair(post_id_a, post_id_b) end),
        index_unindexed_posts: zero_or_one_arg(fn _args -> index_unindexed_posts(project_id) end)
      }
    }
  end
end
