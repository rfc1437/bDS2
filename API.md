# API Documentation

Contract version: 0.3.1

This reference documents the Lua runtime API available through `bds` in embedded bDS2 scripts.

`bds` is available in project-scoped Lua scripts executed through the bDS2 scripting runtime.

## Usage

```lua
local project = bds.projects.get_active()
local meta = bds.meta.get_project_metadata()
```

## Table of contents

- [app](#app)
- [projects](#projects)
- [posts](#posts)
- [media](#media)
- [scripts](#scripts)
- [templates](#templates)
- [meta](#meta)
- [tags](#tags)
- [tasks](#tasks)
- [sync](#sync)
- [publish](#publish)
- [chat](#chat)
- [embeddings](#embeddings)
- [Data Structures](#data-structures)

## app

### app.get_data_paths

Return filesystem paths for the current application and project data.

**Parameters**

- None

**Response specification**

- Return type: `table`

**Example call**

```lua
local result = bds.app.get_data_paths()
```

### app.get_default_project_path

Return the current project's filesystem path.

**Parameters**

- None

**Response specification**

- Return type: `string | nil`

**Example call**

```lua
local result = bds.app.get_default_project_path()
```

### app.get_system_language

Return the current UI locale.

**Parameters**

- None

**Response specification**

- Return type: `string | nil`

**Example call**

```lua
local result = bds.app.get_system_language()
```

### app.read_project_metadata

Read project metadata from a project folder path.

**Parameters**

- folder_path (string, required)

**Response specification**

- Return type: `ProjectMetadata | nil`

**Example call**

```lua
local result = bds.app.read_project_metadata("value")
```


## chat

### chat.analyze_media_image

Analyze a media image using the configured AI runtime.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.chat.analyze_media_image("value")
```

### chat.analyze_post

Analyze a post using the configured AI runtime.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.chat.analyze_post("value")
```

### chat.detect_media_language

Detect the language of media metadata.

**Parameters**

- title (string, required)
- alt (string, optional)
- caption (string, optional)

**Response specification**

- Return type: `table`

**Example call**

```lua
local result = bds.chat.detect_media_language("value", "value", "value")
```

### chat.detect_post_language

Detect the language of post title and content.

**Parameters**

- title (string, required)
- content (string, required)

**Response specification**

- Return type: `table`

**Example call**

```lua
local result = bds.chat.detect_post_language("value", "value")
```

### chat.translate_media_metadata

Translate media metadata and persist the translation.

**Parameters**

- media_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.chat.translate_media_metadata("value", "value")
```

### chat.translate_post

Translate a post and persist the translation.

**Parameters**

- post_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.chat.translate_post("value", "value")
```


## embeddings

### embeddings.compute_similarities

Compute similarity scores from one source post to target posts.

**Parameters**

- post_id (string, required)
- target_ids (table, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.compute_similarities("value", {})
```

### embeddings.dismiss_pair

Dismiss a duplicate candidate pair.

**Parameters**

- post_id_a (string, required)
- post_id_b (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.embeddings.dismiss_pair("value", "value")
```

### embeddings.find_duplicates

Find duplicate post candidates for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.find_duplicates()
```

### embeddings.find_similar

Find posts similar to the given post id.

**Parameters**

- post_id (string, required)
- limit (integer, optional)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.find_similar("value", 1)
```

### embeddings.get_progress

Get embedding index progress for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.get_progress()
```

### embeddings.index_unindexed_posts

Index posts missing embeddings for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.index_unindexed_posts()
```

### embeddings.suggest_tags

Suggest tags for a post from semantic similarity.

**Parameters**

- post_id (string, required)
- exclude_tags (table, optional)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.embeddings.suggest_tags("value", {})
```


## media

### media.import

Import media into the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `MediaData | nil`

**Example call**

```lua
local result = bds.media.import({})
```

### media.update

Update media metadata by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `MediaData | nil`

**Example call**

```lua
local result = bds.media.update("value", {})
```

### media.delete

Delete a media item by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.media.delete("value")
```

### media.get

Fetch one media item by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `MediaData | nil`

**Example call**

```lua
local result = bds.media.get("value")
```

### media.get_all

Fetch all media in the current project.

**Parameters**

- None

**Response specification**

- Return type: `MediaData[]`

**Example call**

```lua
local result = bds.media.get_all()
```


## meta

### meta.add_category

Add a category to the current project.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `ProjectMetadata | nil`

**Example call**

```lua
local result = bds.meta.add_category("value")
```

### meta.add_tag

Add a tag record to the current project if it does not already exist.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.meta.add_tag("value")
```

### meta.clear_publishing_preferences

Reset publishing preferences to defaults.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.meta.clear_publishing_preferences()
```

### meta.get_categories

Get project categories.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.meta.get_categories()
```

### meta.get_project_metadata

Read metadata for the current project.

**Parameters**

- None

**Response specification**

- Return type: `ProjectMetadata`

**Example call**

```lua
local result = bds.meta.get_project_metadata()
```

### meta.get_publishing_preferences

Get publishing preferences for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.meta.get_publishing_preferences()
```

### meta.get_tags

Get tag names for the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.meta.get_tags()
```

### meta.remove_category

Remove a category from the current project.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `ProjectMetadata | nil`

**Example call**

```lua
local result = bds.meta.remove_category("value")
```

### meta.remove_tag

Remove a tag record from the current project by name.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.meta.remove_tag("value")
```

### meta.set_project_metadata

Replace project metadata fields for the current project.

**Parameters**

- updates (table, required)

**Response specification**

- Return type: `ProjectMetadata | nil`

**Example call**

```lua
local result = bds.meta.set_project_metadata({})
```

### meta.set_publishing_preferences

Set publishing preferences for the current project.

**Parameters**

- prefs (table, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.meta.set_publishing_preferences({})
```

### meta.update_project_metadata

Update metadata for the current project.

**Parameters**

- updates (table, required)

**Response specification**

- Return type: `ProjectMetadata | nil`

**Example call**

```lua
local result = bds.meta.update_project_metadata({})
```


## posts

### posts.create

Create a post in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `PostData | nil`

**Example call**

```lua
local result = bds.posts.create({})
```

### posts.update

Update a post by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `PostData | nil`

**Example call**

```lua
local result = bds.posts.update("value", {})
```

### posts.delete

Delete a post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.posts.delete("value")
```

### posts.get

Fetch one post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `PostData | nil`

**Example call**

```lua
local result = bds.posts.get("value")
```

### posts.get_all

Fetch all posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `PostData[]`

**Example call**

```lua
local result = bds.posts.get_all()
```

### posts.get_by_slug

Fetch one post by slug.

**Parameters**

- slug (string, required)

**Response specification**

- Return type: `PostData | nil`

**Example call**

```lua
local result = bds.posts.get_by_slug("value")
```

### posts.get_categories

Get category names used by posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.posts.get_categories()
```

### posts.get_categories_with_counts

Get post categories with usage counts.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example call**

```lua
local result = bds.posts.get_categories_with_counts()
```

### posts.get_tags

Get tag names used by posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.posts.get_tags()
```

### posts.get_tags_with_counts

Get post tags with usage counts.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example call**

```lua
local result = bds.posts.get_tags_with_counts()
```

### posts.get_translation

Get a single translation for a post by language.

**Parameters**

- post_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.posts.get_translation("value", "value")
```

### posts.get_translations

Get all translations for a post.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table[]`

**Example call**

```lua
local result = bds.posts.get_translations("value")
```

### posts.has_published_version

Check whether a post has a published version.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.posts.has_published_version("value")
```

### posts.publish

Publish a post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `PostData | nil`

**Example call**

```lua
local result = bds.posts.publish("value")
```

### posts.rebuild_from_files

Rebuild post records from published files.

**Parameters**

- None

**Response specification**

- Return type: `PostData[] | nil`

**Example call**

```lua
local result = bds.posts.rebuild_from_files()
```

### posts.reindex_text

Reindex post and media search text for the current project.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.posts.reindex_text()
```

### posts.search

Search posts by free-text query.

**Parameters**

- query (string, required)

**Response specification**

- Return type: `PostData[] | nil`

**Example call**

```lua
local result = bds.posts.search("value")
```


## projects

### projects.create

Create a project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `ProjectData | nil`

**Example call**

```lua
local result = bds.projects.create({})
```

### projects.delete

Delete a project by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.projects.delete("value")
```

### projects.delete_with_data

Delete a project by id and remove its project directory.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.projects.delete_with_data("value")
```

### projects.get

Fetch one project by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ProjectData | nil`

**Example call**

```lua
local result = bds.projects.get("value")
```

### projects.get_all

Fetch all projects.

**Parameters**

- None

**Response specification**

- Return type: `ProjectData[]`

**Example call**

```lua
local result = bds.projects.get_all()
```

### projects.get_active

Fetch the active project.

**Parameters**

- None

**Response specification**

- Return type: `ProjectData | nil`

**Example call**

```lua
local result = bds.projects.get_active()
```

### projects.set_active

Set the active project by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ProjectData | nil`

**Example call**

```lua
local result = bds.projects.set_active("value")
```

### projects.update

Update a project by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `ProjectData | nil`

**Example call**

```lua
local result = bds.projects.update("value", {})
```


## publish

### publish.upload_site

Upload the rendered site using the provided publishing credentials.

**Parameters**

- credentials (table, required)

**Response specification**

- Return type: `TaskData | nil`

**Example call**

```lua
local result = bds.publish.upload_site({})
```


## scripts

### scripts.create

Create a script in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `ScriptData | nil`

**Example call**

```lua
local result = bds.scripts.create({})
```

### scripts.update

Update a script by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `ScriptData | nil`

**Example call**

```lua
local result = bds.scripts.update("value", {})
```

### scripts.delete

Delete a script by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.scripts.delete("value")
```

### scripts.get

Fetch one script by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ScriptData | nil`

**Example call**

```lua
local result = bds.scripts.get("value")
```

### scripts.get_all

Fetch all scripts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `ScriptData[]`

**Example call**

```lua
local result = bds.scripts.get_all()
```

### scripts.publish

Publish a script by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ScriptData | nil`

**Example call**

```lua
local result = bds.scripts.publish("value")
```

### scripts.rebuild_from_files

Rebuild script records from published files.

**Parameters**

- None

**Response specification**

- Return type: `ScriptData[] | nil`

**Example call**

```lua
local result = bds.scripts.rebuild_from_files()
```


## sync

### sync.check_availability

Return whether Git is available on the current machine.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.sync.check_availability()
```

### sync.commit_all

Commit all pending repository changes for the current project.

**Parameters**

- message (string, required)

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.commit_all("value")
```

### sync.fetch

Fetch remote Git refs for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.fetch()
```

### sync.get_history

Return commit history for the current project repository.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.get_history()
```

### sync.get_remote_state

Return remote repository state information for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.get_remote_state()
```

### sync.get_repo_state

Return repository state information for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.get_repo_state()
```

### sync.get_status

Return Git status information for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.get_status()
```

### sync.pull

Pull remote changes for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.pull()
```

### sync.push

Push local changes for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`

**Example call**

```lua
local result = bds.sync.push()
```


## tags

### tags.create

Create a tag in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `TagData | nil`

**Example call**

```lua
local result = bds.tags.create({})
```

### tags.update

Update a tag by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `TagData | nil`

**Example call**

```lua
local result = bds.tags.update("value", {})
```

### tags.delete

Delete a tag by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.tags.delete("value")
```

### tags.get

Fetch one tag by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TagData | nil`

**Example call**

```lua
local result = bds.tags.get("value")
```

### tags.get_all

Fetch all tags in the current project.

**Parameters**

- None

**Response specification**

- Return type: `TagData[]`

**Example call**

```lua
local result = bds.tags.get_all()
```

### tags.get_by_name

Fetch one tag by name.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `TagData | nil`

**Example call**

```lua
local result = bds.tags.get_by_name("value")
```

### tags.get_posts_with_tag

Get post ids using a specific tag.

**Parameters**

- tag_id (string, required)

**Response specification**

- Return type: `string[]`

**Example call**

```lua
local result = bds.tags.get_posts_with_tag("value")
```

### tags.get_with_counts

Fetch tags with usage counts.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example call**

```lua
local result = bds.tags.get_with_counts()
```

### tags.merge

Merge source tags into a target tag.

**Parameters**

- source_tag_ids (table, required)
- target_tag_id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.tags.merge({}, "value")
```

### tags.rename

Rename a tag by id.

**Parameters**

- id (string, required)
- new_name (string, required)

**Response specification**

- Return type: `TagData | nil`

**Example call**

```lua
local result = bds.tags.rename("value", "value")
```

### tags.sync_from_posts

Sync tag records from post tags.

**Parameters**

- None

**Response specification**

- Return type: `TagData[] | nil`

**Example call**

```lua
local result = bds.tags.sync_from_posts()
```


## tasks

### tasks.cancel

Cancel a task by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.tasks.cancel("value")
```

### tasks.clear_completed

Clear completed tasks from the in-memory task list.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.tasks.clear_completed()
```

### tasks.get

Fetch one task by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TaskData | nil`

**Example call**

```lua
local result = bds.tasks.get("value")
```

### tasks.get_all

Fetch all tasks currently tracked by the task manager.

**Parameters**

- None

**Response specification**

- Return type: `TaskData[]`

**Example call**

```lua
local result = bds.tasks.get_all()
```

### tasks.get_running

Fetch running tasks currently tracked by the task manager.

**Parameters**

- None

**Response specification**

- Return type: `TaskData[]`

**Example call**

```lua
local result = bds.tasks.get_running()
```

### tasks.status_snapshot

Fetch the current task status snapshot.

**Parameters**

- None

**Response specification**

- Return type: `TaskStatus`

**Example call**

```lua
local result = bds.tasks.status_snapshot()
```


## templates

### templates.create

Create a template in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `TemplateData | nil`

**Example call**

```lua
local result = bds.templates.create({})
```

### templates.update

Update a template by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `TemplateData | nil`

**Example call**

```lua
local result = bds.templates.update("value", {})
```

### templates.delete

Delete a template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example call**

```lua
local result = bds.templates.delete("value")
```

### templates.get

Fetch one template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TemplateData | nil`

**Example call**

```lua
local result = bds.templates.get("value")
```

### templates.get_all

Fetch all templates in the current project.

**Parameters**

- None

**Response specification**

- Return type: `TemplateData[]`

**Example call**

```lua
local result = bds.templates.get_all()
```

### templates.get_enabled_by_kind

Fetch enabled templates filtered by kind.

**Parameters**

- kind (string, required)

**Response specification**

- Return type: `TemplateData[]`

**Example call**

```lua
local result = bds.templates.get_enabled_by_kind("value")
```

### templates.publish

Publish a template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TemplateData | nil`

**Example call**

```lua
local result = bds.templates.publish("value")
```

### templates.rebuild_from_files

Rebuild template records from published files.

**Parameters**

- None

**Response specification**

- Return type: `TemplateData[] | nil`

**Example call**

```lua
local result = bds.templates.rebuild_from_files()
```

### templates.validate

Validate Liquid template syntax.

**Parameters**

- content (string, required)

**Response specification**

- Return type: `ValidationResult | nil`

**Example call**

```lua
local result = bds.templates.validate("value")
```



## Data Structures

### ProjectData

Project record stored in the application database.

- `id`: `string`
- `name`: `string`
- `slug`: `string`
- `description`: `string | nil`
- `data_path`: `string | nil`
- `is_active`: `boolean`
- `created_at`: `integer`
- `updated_at`: `integer`

### ProjectMetadata

Current project metadata and publishing settings snapshot.

- `name`: `string`
- `description`: `string | nil`
- `public_url`: `string | nil`
- `main_language`: `string | nil`
- `default_author`: `string | nil`
- `categories`: `string[]`
- `blog_languages`: `string[]`
- `publishing_preferences`: `table`

### PostData

Post record with link graph data added for scripting.

- `id`: `string`
- `project_id`: `string`
- `title`: `string`
- `slug`: `string`
- `status`: `string`
- `language`: `string | nil`
- `tags`: `string[]`
- `categories`: `string[]`
- `backlinks`: `table[]`
- `links_to`: `table[]`

### MediaData

Media record stored for a project.

- `id`: `string`
- `project_id`: `string`
- `original_name`: `string`
- `mime_type`: `string`
- `file_path`: `string`
- `title`: `string | nil`
- `alt`: `string | nil`
- `caption`: `string | nil`
- `tags`: `string[]`

### ScriptData

Lua script record.

- `id`: `string`
- `project_id`: `string`
- `slug`: `string`
- `title`: `string`
- `kind`: `string`
- `entrypoint`: `string`
- `enabled`: `boolean`
- `status`: `string`

### TemplateData

Template record for site rendering.

- `id`: `string`
- `project_id`: `string`
- `slug`: `string`
- `title`: `string`
- `kind`: `string`
- `enabled`: `boolean`
- `status`: `string`

### TagData

Tag record stored for a project.

- `id`: `string`
- `project_id`: `string`
- `name`: `string`
- `color`: `string | nil`
- `post_template_slug`: `string | nil`

### TaskData

Public task snapshot returned by the task manager.

- `id`: `string`
- `name`: `string`
- `status`: `string`
- `progress`: `number | table | nil`
- `message`: `string | nil`

### TaskStatus

Aggregate task status snapshot.

- `active_count`: `integer`
- `running_count`: `integer`
- `pending_count`: `integer`
- `tasks`: `TaskData[]`

### ValidationResult

Template validation result.

- `valid`: `boolean`
- `errors`: `string[]`
