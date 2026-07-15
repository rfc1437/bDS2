defmodule BDS.Scripting.ApiDocs do
  @moduledoc """
  Machine-readable documentation for the Lua scripting API, used to generate
  help text, autocompletion data, and the published API reference.
  """

  @version "0.4.0"

  @methods [
    %{
      module: "app",
      name: "copy_to_clipboard",
      description: "Copy text to the system clipboard.",
      params: [%{name: "text", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "app",
      name: "get_blogmark_bookmarklet",
      description: "Return the Blogmark bookmarklet JavaScript source.",
      params: [],
      returns: "string"
    },
    %{
      module: "app",
      name: "get_data_paths",
      description: "Return filesystem paths for the current application and project data.",
      params: [],
      returns: "table"
    },
    %{
      module: "app",
      name: "get_default_project_path",
      description: "Return the current project's filesystem path.",
      params: [],
      returns: "string | nil"
    },
    %{
      module: "app",
      name: "get_system_language",
      description:
        "Return the current UI locale (the server-side UI language setting, falling back to the OS locale when unset).",
      params: [],
      returns: "string | nil"
    },
    %{
      module: "app",
      name: "get_title_bar_metrics",
      description: "Return desktop title bar inset metrics when available.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "app",
      name: "notify_renderer_ready",
      description: "Notify the host application that the renderer is ready.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "app",
      name: "open_folder",
      description: "Open a folder in the system file manager.",
      params: [%{name: "folder_path", type: "string", required: true}],
      returns: "string"
    },
    %{
      module: "app",
      name: "read_project_metadata",
      description: "Read project metadata from a project folder path.",
      params: [%{name: "folder_path", type: "string", required: true}],
      returns: "ProjectMetadata | nil"
    },
    %{
      module: "app",
      name: "select_folder",
      description: "Show the native folder picker and return the chosen path.",
      params: [%{name: "title", type: "string", required: false}],
      returns: "string | nil"
    },
    %{
      module: "app",
      name: "set_preview_post_target",
      description: "Set the current preview-post target used by desktop integrations.",
      params: [%{name: "post_id", type: "string", required: false}],
      returns: "boolean"
    },
    %{
      module: "app",
      name: "show_item_in_folder",
      description: "Reveal a file or folder in the system file manager.",
      params: [%{name: "item_path", type: "string", required: true}],
      returns: "nil"
    },
    %{
      module: "app",
      name: "trigger_menu_action",
      description: "Trigger a native menu action by action id.",
      params: [%{name: "action", type: "string", required: true}],
      returns: "nil"
    },
    %{
      module: "projects",
      name: "create",
      description: "Create a project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "ProjectData | nil"
    },
    %{
      module: "projects",
      name: "delete",
      description: "Delete a project by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "projects",
      name: "delete_with_data",
      description: "Delete a project by id and remove its project directory.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "projects",
      name: "get",
      description: "Fetch one project by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "ProjectData | nil"
    },
    %{
      module: "projects",
      name: "get_all",
      description: "Fetch all projects.",
      params: [],
      returns: "ProjectData[]"
    },
    %{
      module: "projects",
      name: "get_active",
      description: "Fetch the active project.",
      params: [],
      returns: "ProjectData | nil"
    },
    %{
      module: "projects",
      name: "set_active",
      description: "Set the active project by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "ProjectData | nil"
    },
    %{
      module: "projects",
      name: "update",
      description: "Update a project by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "ProjectData | nil"
    },
    %{
      module: "posts",
      name: "create",
      description: "Create a post in the current project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "update",
      description: "Update a post by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "delete",
      description: "Delete a post by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "posts",
      name: "discard",
      description:
        "Discard unpublished post changes and restore the last published version from disk.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "filter",
      description:
        "Filter posts using status, tags, categories, language, year, month, or date range fields.",
      params: [%{name: "filters", type: "table", required: true}],
      returns: "PostData[] | nil"
    },
    %{
      module: "posts",
      name: "generate_unique_slug",
      description: "Generate a unique slug from a title, optionally excluding one post id.",
      params: [
        %{name: "title", type: "string", required: true},
        %{name: "exclude_post_id", type: "string", required: false}
      ],
      returns: "string"
    },
    %{
      module: "posts",
      name: "get",
      description: "Fetch one post by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "get_all",
      description: "Fetch all posts in the current project.",
      params: [],
      returns: "PostData[]"
    },
    %{
      module: "posts",
      name: "get_by_slug",
      description: "Fetch one post by slug.",
      params: [%{name: "slug", type: "string", required: true}],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "get_by_status",
      description: "Fetch posts filtered by a specific status.",
      params: [%{name: "status", type: "string", required: true}],
      returns: "PostData[]"
    },
    %{
      module: "posts",
      name: "get_by_year_month",
      description: "Get post counts grouped by year and month.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "get_categories",
      description: "Get category names used by posts in the current project.",
      params: [],
      returns: "string[]"
    },
    %{
      module: "posts",
      name: "get_categories_with_counts",
      description: "Get post categories with usage counts.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "get_dashboard_stats",
      description: "Return aggregate post dashboard counts for the current project.",
      params: [],
      returns: "table"
    },
    %{
      module: "posts",
      name: "get_linked_by",
      description: "Return posts that link to the given post.",
      params: [%{name: "post_id", type: "string", required: true}],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "get_links_to",
      description: "Return posts linked from the given post.",
      params: [%{name: "post_id", type: "string", required: true}],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "get_preview_url",
      description:
        "Return the local preview URL for a post, optionally with draft and language query parameters.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "options", type: "table", required: false}
      ],
      returns: "string | nil"
    },
    %{
      module: "posts",
      name: "get_tags",
      description: "Get tag names used by posts in the current project.",
      params: [],
      returns: "string[]"
    },
    %{
      module: "posts",
      name: "get_tags_with_counts",
      description: "Get post tags with usage counts.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "get_translation",
      description: "Get a single translation for a post by language.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "posts",
      name: "get_translations",
      description: "Get all translations for a post.",
      params: [%{name: "post_id", type: "string", required: true}],
      returns: "table[]"
    },
    %{
      module: "posts",
      name: "has_published_version",
      description: "Check whether a post has a published version.",
      params: [%{name: "post_id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "posts",
      name: "is_slug_available",
      description:
        "Return whether a slug is available in the current project, optionally excluding one post id.",
      params: [
        %{name: "slug", type: "string", required: true},
        %{name: "exclude_post_id", type: "string", required: false}
      ],
      returns: "boolean"
    },
    %{
      module: "posts",
      name: "publish",
      description: "Publish a post by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "PostData | nil"
    },
    %{
      module: "posts",
      name: "publish_translation",
      description: "Publish one translation of a post by language.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "posts",
      name: "rebuild_from_files",
      description: "Rebuild post records from published files.",
      params: [],
      returns: "PostData[] | nil"
    },
    %{
      module: "posts",
      name: "rebuild_links",
      description: "Rebuild the post link graph for the current project.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "posts",
      name: "reindex_text",
      description: "Reindex post and media search text for the current project.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "posts",
      name: "search",
      description: "Search posts by free-text query.",
      params: [%{name: "query", type: "string", required: true}],
      returns: "PostData[] | nil"
    },
    %{
      module: "media",
      name: "delete_translation",
      description: "Delete a media translation by language.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "boolean"
    },
    %{
      module: "media",
      name: "filter",
      description: "Filter media using year, month, tags, language, or date range fields.",
      params: [%{name: "filters", type: "table", required: true}],
      returns: "MediaData[]"
    },
    %{
      module: "media",
      name: "import",
      description: "Import media into the current project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "MediaData | nil"
    },
    %{
      module: "media",
      name: "get_by_year_month",
      description: "Get media counts grouped by year and month.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "media",
      name: "get_file_path",
      description: "Return the absolute file path for a media item.",
      params: [%{name: "media_id", type: "string", required: true}],
      returns: "string | nil"
    },
    %{
      module: "media",
      name: "update",
      description: "Update media metadata by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "MediaData | nil"
    },
    %{
      module: "media",
      name: "delete",
      description: "Delete a media item by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "media",
      name: "get",
      description: "Fetch one media item by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "MediaData | nil"
    },
    %{
      module: "media",
      name: "get_all",
      description: "Fetch all media in the current project.",
      params: [],
      returns: "MediaData[]"
    },
    %{
      module: "media",
      name: "get_tags",
      description: "Return tag names used by media in the current project.",
      params: [],
      returns: "string[]"
    },
    %{
      module: "media",
      name: "get_tags_with_counts",
      description: "Return media tags with usage counts.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "media",
      name: "get_thumbnail",
      description: "Return a media thumbnail as a data URL for the requested size.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "size", type: "string", required: false}
      ],
      returns: "string | nil"
    },
    %{
      module: "media",
      name: "get_translation",
      description: "Return one media translation by language.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "media",
      name: "get_translations",
      description: "Return all translations for a media item.",
      params: [%{name: "media_id", type: "string", required: true}],
      returns: "table[]"
    },
    %{
      module: "media",
      name: "get_url",
      description: "Return the project-relative public URL path for a media item.",
      params: [%{name: "media_id", type: "string", required: true}],
      returns: "string | nil"
    },
    %{
      module: "media",
      name: "rebuild_from_files",
      description: "Rebuild media records from sidecar files on disk.",
      params: [],
      returns: "MediaData[] | nil"
    },
    %{
      module: "media",
      name: "regenerate_missing_thumbnails",
      description: "Generate thumbnails for media items that are missing them.",
      params: [],
      returns: "table"
    },
    %{
      module: "media",
      name: "regenerate_thumbnails",
      description: "Regenerate all thumbnails for one media item.",
      params: [%{name: "media_id", type: "string", required: true}],
      returns: "table | nil"
    },
    %{
      module: "media",
      name: "reindex_text",
      description: "Reindex post and media search text for the current project.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "media",
      name: "replace_file",
      description: "Replace the binary file behind an existing media item.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "source_path", type: "string", required: true}
      ],
      returns: "MediaData | nil"
    },
    %{
      module: "media",
      name: "search",
      description: "Search media by free-text query.",
      params: [%{name: "query", type: "string", required: true}],
      returns: "MediaData[] | nil"
    },
    %{
      module: "media",
      name: "upsert_translation",
      description: "Create or update a media translation.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "language", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "scripts",
      name: "create",
      description: "Create a script in the current project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "ScriptData | nil"
    },
    %{
      module: "scripts",
      name: "update",
      description: "Update a script by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "ScriptData | nil"
    },
    %{
      module: "scripts",
      name: "delete",
      description: "Delete a script by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "scripts",
      name: "get",
      description: "Fetch one script by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "ScriptData | nil"
    },
    %{
      module: "scripts",
      name: "get_all",
      description: "Fetch all scripts in the current project.",
      params: [],
      returns: "ScriptData[]"
    },
    %{
      module: "scripts",
      name: "publish",
      description: "Publish a script by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "ScriptData | nil"
    },
    %{
      module: "scripts",
      name: "rebuild_from_files",
      description: "Rebuild script records from published files.",
      params: [],
      returns: "ScriptData[] | nil"
    },
    %{
      module: "templates",
      name: "create",
      description: "Create a template in the current project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "TemplateData | nil"
    },
    %{
      module: "templates",
      name: "update",
      description: "Update a template by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "TemplateData | nil"
    },
    %{
      module: "templates",
      name: "delete",
      description: "Delete a template by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "templates",
      name: "get",
      description: "Fetch one template by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "TemplateData | nil"
    },
    %{
      module: "templates",
      name: "get_all",
      description: "Fetch all templates in the current project.",
      params: [],
      returns: "TemplateData[]"
    },
    %{
      module: "templates",
      name: "get_enabled_by_kind",
      description: "Fetch enabled templates filtered by kind.",
      params: [%{name: "kind", type: "string", required: true}],
      returns: "TemplateData[]"
    },
    %{
      module: "templates",
      name: "publish",
      description: "Publish a template by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "TemplateData | nil"
    },
    %{
      module: "templates",
      name: "rebuild_from_files",
      description: "Rebuild template records from published files.",
      params: [],
      returns: "TemplateData[] | nil"
    },
    %{
      module: "templates",
      name: "validate",
      description: "Validate Liquid template syntax.",
      params: [%{name: "content", type: "string", required: true}],
      returns: "ValidationResult | nil"
    },
    %{
      module: "meta",
      name: "add_category",
      description: "Add a category to the current project.",
      params: [%{name: "name", type: "string", required: true}],
      returns: "ProjectMetadata | nil"
    },
    %{
      module: "meta",
      name: "add_tag",
      description: "Add a tag record to the current project if it does not already exist.",
      params: [%{name: "name", type: "string", required: true}],
      returns: "string[]"
    },
    %{
      module: "meta",
      name: "clear_publishing_preferences",
      description: "Reset publishing preferences to defaults.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "meta",
      name: "get_categories",
      description: "Get project categories.",
      params: [],
      returns: "string[]"
    },
    %{
      module: "meta",
      name: "get_project_metadata",
      description: "Read metadata for the current project.",
      params: [],
      returns: "ProjectMetadata"
    },
    %{
      module: "meta",
      name: "get_publishing_preferences",
      description: "Get publishing preferences for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "meta",
      name: "get_tags",
      description: "Get tag names for the current project.",
      params: [],
      returns: "string[]"
    },
    %{
      module: "meta",
      name: "remove_category",
      description: "Remove a category from the current project.",
      params: [%{name: "name", type: "string", required: true}],
      returns: "ProjectMetadata | nil"
    },
    %{
      module: "meta",
      name: "remove_tag",
      description: "Remove a tag record from the current project by name.",
      params: [%{name: "name", type: "string", required: true}],
      returns: "string[]"
    },
    %{
      module: "meta",
      name: "set_project_metadata",
      description: "Replace project metadata fields for the current project.",
      params: [%{name: "updates", type: "table", required: true}],
      returns: "ProjectMetadata | nil"
    },
    %{
      module: "meta",
      name: "set_publishing_preferences",
      description: "Set publishing preferences for the current project.",
      params: [%{name: "prefs", type: "table", required: true}],
      returns: "table | nil"
    },
    %{
      module: "meta",
      name: "sync_on_startup",
      description:
        "Synchronize startup metadata state and return tags, categories, and project metadata.",
      params: [],
      returns: "table"
    },
    %{
      module: "meta",
      name: "update_project_metadata",
      description: "Update metadata for the current project.",
      params: [%{name: "updates", type: "table", required: true}],
      returns: "ProjectMetadata | nil"
    },
    %{
      module: "tags",
      name: "create",
      description: "Create a tag in the current project.",
      params: [%{name: "data", type: "table", required: true}],
      returns: "TagData | nil"
    },
    %{
      module: "tags",
      name: "update",
      description: "Update a tag by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "data", type: "table", required: true}
      ],
      returns: "TagData | nil"
    },
    %{
      module: "tags",
      name: "delete",
      description: "Delete a tag by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "tags",
      name: "get",
      description: "Fetch one tag by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "TagData | nil"
    },
    %{
      module: "tags",
      name: "get_all",
      description: "Fetch all tags in the current project.",
      params: [],
      returns: "TagData[]"
    },
    %{
      module: "tags",
      name: "get_by_name",
      description: "Fetch one tag by name.",
      params: [%{name: "name", type: "string", required: true}],
      returns: "TagData | nil"
    },
    %{
      module: "tags",
      name: "get_posts_with_tag",
      description: "Get post ids using a specific tag.",
      params: [%{name: "tag_id", type: "string", required: true}],
      returns: "string[]"
    },
    %{
      module: "tags",
      name: "get_with_counts",
      description: "Fetch tags with usage counts.",
      params: [],
      returns: "table[]"
    },
    %{
      module: "tags",
      name: "merge",
      description: "Merge source tags into a target tag.",
      params: [
        %{name: "source_tag_ids", type: "table", required: true},
        %{name: "target_tag_id", type: "string", required: true}
      ],
      returns: "boolean"
    },
    %{
      module: "tags",
      name: "rename",
      description: "Rename a tag by id.",
      params: [
        %{name: "id", type: "string", required: true},
        %{name: "new_name", type: "string", required: true}
      ],
      returns: "TagData | nil"
    },
    %{
      module: "tags",
      name: "sync_from_posts",
      description: "Sync tag records from post tags.",
      params: [],
      returns: "TagData[] | nil"
    },
    %{
      module: "tasks",
      name: "cancel",
      description: "Cancel a task by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "boolean"
    },
    %{
      module: "tasks",
      name: "clear_completed",
      description: "Clear completed tasks from the in-memory task list.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "tasks",
      name: "get",
      description: "Fetch one task by id.",
      params: [%{name: "id", type: "string", required: true}],
      returns: "TaskData | nil"
    },
    %{
      module: "tasks",
      name: "get_all",
      description: "Fetch all tasks currently tracked by the task manager.",
      params: [],
      returns: "TaskData[]"
    },
    %{
      module: "tasks",
      name: "get_running",
      description: "Fetch running tasks currently tracked by the task manager.",
      params: [],
      returns: "TaskData[]"
    },
    %{
      module: "tasks",
      name: "status_snapshot",
      description: "Fetch the current task status snapshot.",
      params: [],
      returns: "TaskStatus"
    },
    %{
      module: "sync",
      name: "check_availability",
      description: "Return whether Git is available on the current machine.",
      params: [],
      returns: "boolean"
    },
    %{
      module: "sync",
      name: "commit_all",
      description: "Commit all pending repository changes for the current project.",
      params: [%{name: "message", type: "string", required: true}],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "fetch",
      description: "Fetch remote Git refs for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "get_history",
      description: "Return commit history for the current project repository.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "get_remote_state",
      description: "Return remote repository state information for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "get_repo_state",
      description: "Return repository state information for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "get_status",
      description: "Return Git status information for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "pull",
      description: "Pull remote changes for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "sync",
      name: "push",
      description: "Push local changes for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "publish",
      name: "upload_site",
      description: "Upload the rendered site using the provided publishing credentials.",
      params: [%{name: "credentials", type: "table", required: true}],
      returns: "TaskData | nil"
    },
    %{
      module: "chat",
      name: "analyze_media_image",
      description: "Analyze a media image using the configured AI runtime.",
      params: [%{name: "media_id", type: "string", required: true}],
      returns: "table | nil"
    },
    %{
      module: "chat",
      name: "analyze_post",
      description: "Analyze a post using the configured AI runtime.",
      params: [%{name: "post_id", type: "string", required: true}],
      returns: "table | nil"
    },
    %{
      module: "chat",
      name: "detect_media_language",
      description: "Detect the language of media metadata.",
      params: [
        %{name: "title", type: "string", required: true},
        %{name: "alt", type: "string", required: false},
        %{name: "caption", type: "string", required: false}
      ],
      returns: "table"
    },
    %{
      module: "chat",
      name: "detect_post_language",
      description: "Detect the language of post title and content.",
      params: [
        %{name: "title", type: "string", required: true},
        %{name: "content", type: "string", required: true}
      ],
      returns: "table"
    },
    %{
      module: "chat",
      name: "translate_media_metadata",
      description: "Translate media metadata and persist the translation.",
      params: [
        %{name: "media_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "chat",
      name: "translate_post",
      description: "Translate a post and persist the translation.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "language", type: "string", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "compute_similarities",
      description: "Compute similarity scores from one source post to target posts.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "target_ids", type: "table", required: true}
      ],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "dismiss_pair",
      description: "Dismiss a duplicate candidate pair.",
      params: [
        %{name: "post_id_a", type: "string", required: true},
        %{name: "post_id_b", type: "string", required: true}
      ],
      returns: "boolean"
    },
    %{
      module: "embeddings",
      name: "find_duplicates",
      description: "Find duplicate post candidates for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "find_similar",
      description: "Find posts similar to the given post id.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "limit", type: "integer", required: false}
      ],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "get_progress",
      description: "Get embedding index progress for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "index_unindexed_posts",
      description: "Index posts missing embeddings for the current project.",
      params: [],
      returns: "table | nil"
    },
    %{
      module: "embeddings",
      name: "suggest_tags",
      description: "Suggest tags for a post from semantic similarity.",
      params: [
        %{name: "post_id", type: "string", required: true},
        %{name: "exclude_tags", type: "table", required: false}
      ],
      returns: "table | nil"
    }
  ]

  @data_structures [
    %{
      name: "ProjectData",
      description: "Project record stored in the application database.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "name", type: "string"},
        %{name: "slug", type: "string"},
        %{name: "description", type: "string | nil"},
        %{name: "data_path", type: "string | nil"},
        %{name: "is_active", type: "boolean"},
        %{name: "created_at", type: "integer"},
        %{name: "updated_at", type: "integer"}
      ]
    },
    %{
      name: "ProjectMetadata",
      description: "Current project metadata and publishing settings snapshot.",
      fields: [
        %{name: "name", type: "string"},
        %{name: "description", type: "string | nil"},
        %{name: "public_url", type: "string | nil"},
        %{name: "main_language", type: "string | nil"},
        %{name: "default_author", type: "string | nil"},
        %{name: "categories", type: "string[]"},
        %{name: "blog_languages", type: "string[]"},
        %{name: "publishing_preferences", type: "table"}
      ]
    },
    %{
      name: "PostData",
      description: "Post record with link graph data added for scripting.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "project_id", type: "string"},
        %{name: "title", type: "string"},
        %{name: "slug", type: "string"},
        %{name: "status", type: "string"},
        %{name: "language", type: "string | nil"},
        %{name: "tags", type: "string[]"},
        %{name: "categories", type: "string[]"},
        %{name: "backlinks", type: "table[]"},
        %{name: "links_to", type: "table[]"}
      ]
    },
    %{
      name: "MediaData",
      description: "Media record stored for a project.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "project_id", type: "string"},
        %{name: "original_name", type: "string"},
        %{name: "mime_type", type: "string"},
        %{name: "file_path", type: "string"},
        %{name: "title", type: "string | nil"},
        %{name: "alt", type: "string | nil"},
        %{name: "caption", type: "string | nil"},
        %{name: "tags", type: "string[]"}
      ]
    },
    %{
      name: "ScriptData",
      description: "Lua script record.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "project_id", type: "string"},
        %{name: "slug", type: "string"},
        %{name: "title", type: "string"},
        %{name: "kind", type: "string"},
        %{name: "entrypoint", type: "string"},
        %{name: "enabled", type: "boolean"},
        %{name: "status", type: "string"}
      ]
    },
    %{
      name: "TemplateData",
      description: "Template record for site rendering.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "project_id", type: "string"},
        %{name: "slug", type: "string"},
        %{name: "title", type: "string"},
        %{name: "kind", type: "string"},
        %{name: "enabled", type: "boolean"},
        %{name: "status", type: "string"}
      ]
    },
    %{
      name: "TagData",
      description: "Tag record stored for a project.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "project_id", type: "string"},
        %{name: "name", type: "string"},
        %{name: "color", type: "string | nil"},
        %{name: "post_template_slug", type: "string | nil"}
      ]
    },
    %{
      name: "TaskData",
      description: "Public task snapshot returned by the task manager.",
      fields: [
        %{name: "id", type: "string"},
        %{name: "name", type: "string"},
        %{name: "status", type: "string"},
        %{name: "progress", type: "number | table | nil"},
        %{name: "message", type: "string | nil"}
      ]
    },
    %{
      name: "TaskStatus",
      description: "Aggregate task status snapshot.",
      fields: [
        %{name: "active_count", type: "integer"},
        %{name: "running_count", type: "integer"},
        %{name: "pending_count", type: "integer"},
        %{name: "tasks", type: "TaskData[]"}
      ]
    },
    %{
      name: "ValidationResult",
      description: "Template validation result.",
      fields: [%{name: "valid", type: "boolean"}, %{name: "errors", type: "string[]"}]
    }
  ]

  @spec render() :: String.t()
  def render do
    [
      "# API Documentation",
      "",
      "Contract version: #{@version}",
      "",
      "This reference documents the Lua runtime API available through `bds` in embedded bDS2 scripts.",
      "",
      "`bds` is available in project-scoped Lua scripts executed through the bDS2 scripting runtime.",
      "",
      "## Usage",
      "",
      "```lua",
      "local project = bds.projects.get_active()",
      "local meta = bds.meta.get_project_metadata()",
      "```",
      "",
      "## Table of contents",
      "",
      table_of_contents(),
      "",
      render_modules(),
      "",
      "## Data Structures",
      "",
      render_data_structures()
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp table_of_contents do
    module_names()
    |> Enum.map(fn module_name -> "- [#{module_name}](##{module_name})" end)
    |> Kernel.++(["- [Data Structures](#data-structures)"])
  end

  defp render_modules do
    module_names()
    |> Enum.flat_map(fn module_name ->
      methods = module_methods(module_name)

      [
        "## #{module_name}",
        "",
        "**Module APIs**",
        "",
        Enum.map(methods, fn method ->
          "- [#{method.module}.#{method.name}](##{method.module}#{method.name})"
        end),
        "",
        Enum.map(methods, &render_method/1),
        "[↑ Back to Table of contents](#table-of-contents)",
        ""
      ]
    end)
  end

  defp render_method(method) do
    [
      "### #{method.module}.#{method.name}",
      "",
      method.description,
      "",
      "**Parameters**",
      "",
      render_params(method.params),
      "",
      "**Response specification**",
      "",
      "- Return type: `#{method.returns}`",
      render_nullability(method.returns),
      render_data_structure_references(method.returns),
      "",
      "**Example response**",
      "",
      "```lua",
      render_example_response(method.returns),
      "```",
      "",
      "**Example call**",
      "",
      "```lua",
      example_call(method),
      "```",
      ""
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp render_params([]), do: ["- None"]

  defp render_params(params) do
    Enum.map(params, fn param ->
      required = if param.required, do: "required", else: "optional"
      "- #{param.name} (#{param.type}, #{required})"
    end)
  end

  defp example_call(method) do
    args = Enum.map_join(method.params, ", ", &example_argument/1)

    "local result = bds.#{method.module}.#{method.name}(#{args})"
  end

  defp module_names do
    @methods
    |> Enum.map(& &1.module)
    |> Enum.uniq()
  end

  defp module_methods(module_name) do
    Enum.filter(@methods, &(&1.module == module_name))
  end

  defp render_nullability(returns) do
    if nullable_return?(returns) do
      "- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value."
    end
  end

  defp render_data_structure_references(returns) do
    case response_structure_names(returns) do
      [] -> nil
      names -> "- Data structures: `#{Enum.join(names, "`, `")}`"
    end
  end

  defp render_example_response(returns) do
    returns
    |> example_response_value()
    |> render_lua_value(0)
  end

  defp example_argument(%{name: name, type: type}) do
    example_argument_value(name, type)
  end

  defp example_argument_value(name, "string") do
    case name do
      "id" ->
        "\"id-1\""

      suffix when suffix in ["post_id", "media_id", "project_id", "tag_id", "target_tag_id"] ->
        "\"id-1\""

      "source_tag_ids" ->
        "{\"id-1\", \"id-2\"}"

      "language" ->
        "\"en\""

      "status" ->
        "\"draft\""

      "kind" ->
        "\"post\""

      "slug" ->
        "\"example-slug\""

      "title" ->
        "\"Example Title\""

      "name" ->
        "\"Example Name\""

      "query" ->
        "\"example query\""

      "content" ->
        "\"Example content\""

      "message" ->
        "\"Update content\""

      "folder_path" ->
        "\"/Users/me/Sites/example\""

      "source_path" ->
        "\"/Users/me/Pictures/example.jpg\""

      "item_path" ->
        "\"/Users/me/Sites/example/output/index.html\""

      "action" ->
        "\"save\""

      _ ->
        "\"value\""
    end
  end

  defp example_argument_value("limit", "integer"), do: "10"
  defp example_argument_value(_name, "integer"), do: "1"
  defp example_argument_value(_name, "number"), do: "1.0"

  defp example_argument_value(name, "table") do
    case name do
      "data" -> "{title = \"Example Title\"}"
      "filters" -> "{status = \"draft\"}"
      "options" -> "{}"
      "updates" -> "{name = \"Updated Blog\"}"
      "prefs" -> "{provider = \"filesystem\"}"
      "credentials" -> "{provider = \"sftp\"}"
      "target_ids" -> "{\"id-2\", \"id-3\"}"
      "exclude_tags" -> "{\"draft\"}"
      _ -> "{}"
    end
  end

  defp example_argument_value(_name, _type), do: "nil"

  defp nullable_return?(returns), do: String.contains?(returns, "nil")

  defp response_structure_names(returns) do
    structure_names = MapSet.new(Enum.map(@data_structures, & &1.name))

    returns
    |> String.split(~r/\s*\|\s*/)
    |> Enum.map(&String.replace(&1, "[]", ""))
    |> Enum.reject(&(&1 in ["nil", "boolean", "string", "integer", "number", "table"]))
    |> Enum.filter(&MapSet.member?(structure_names, &1))
    |> Enum.uniq()
  end

  defp example_response_value("nil"), do: nil

  defp example_response_value(returns) do
    case {nullable_return?(returns), String.ends_with?(returns, "[]")} do
      {true, _} ->
        {:nullable, example_response_value(non_nil_return(returns))}

      {_, true} ->
        [example_value_for_type(String.trim_trailing(returns, "[]"))]

      _ ->
        example_value_for_type(returns)
    end
  end

  defp non_nil_return(returns) do
    returns
    |> String.split(~r/\s*\|\s*/)
    |> Enum.reject(&(&1 == "nil"))
    |> List.first()
  end

  defp example_value_for_type("boolean"), do: true
  defp example_value_for_type("string"), do: "value"
  defp example_value_for_type("integer"), do: 1
  defp example_value_for_type("number"), do: 1.0
  defp example_value_for_type("nil"), do: nil
  defp example_value_for_type("table"), do: [{"key", "value"}]

  defp example_value_for_type(type) do
    case Enum.find(@data_structures, &(&1.name == type)) do
      nil ->
        [{"key", "value"}]

      structure ->
        Enum.map(structure.fields, fn field -> {field.name, example_field_value(field.type)} end)
    end
  end

  defp example_field_value(type) do
    case {String.contains?(type, " | nil"), String.ends_with?(type, "[]")} do
      {true, _} -> nil
      {_, true} -> [example_value_for_type(String.trim_trailing(type, "[]"))]
      _ -> example_value_for_type(type)
    end
  end

  defp render_lua_value({:nullable, value}, indent) do
    ["nil  -- or", render_lua_value(value, indent)]
    |> Enum.join("\n")
  end

  defp render_lua_value(true, _indent), do: "true"
  defp render_lua_value(false, _indent), do: "false"
  defp render_lua_value(nil, _indent), do: "nil"
  defp render_lua_value(value, _indent) when is_integer(value), do: Integer.to_string(value)

  defp render_lua_value(value, _indent) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact])

  defp render_lua_value(value, _indent) when is_binary(value), do: inspect(value)

  defp render_lua_value([], _indent), do: "{}"

  defp render_lua_value(list, indent) when is_list(list) do
    if keyword_like_list?(list) do
      render_lua_table(list, indent)
    else
      render_lua_array(list, indent)
    end
  end

  defp keyword_like_list?(list) do
    Enum.all?(list, fn
      {key, _value} when is_binary(key) -> true
      _ -> false
    end)
  end

  defp render_lua_table(entries, indent) do
    outer_indent = indent_spaces(indent)
    inner_indent = indent_spaces(indent + 2)

    rendered_entries =
      Enum.map_join(entries, ",\n", fn {key, value} ->
        "#{inner_indent}#{key} = #{render_lua_value(value, indent + 2)}"
      end)

    "{\n#{rendered_entries}\n#{outer_indent}}"
  end

  defp render_lua_array(values, indent) do
    outer_indent = indent_spaces(indent)
    inner_indent = indent_spaces(indent + 2)

    rendered_values =
      Enum.map_join(values, ",\n", fn value ->
        "#{inner_indent}#{render_lua_value(value, indent + 2)}"
      end)

    "{\n#{rendered_values}\n#{outer_indent}}"
  end

  defp indent_spaces(indent), do: String.duplicate(" ", indent)

  defp render_data_structures do
    Enum.flat_map(@data_structures, fn structure ->
      [
        "### #{structure.name}",
        "",
        structure.description,
        "",
        Enum.map(structure.fields, fn field -> "- `#{field.name}`: `#{field.type}`" end),
        ""
      ]
    end)
  end
end
