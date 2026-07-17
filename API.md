# API Documentation

Contract version: 0.4.0

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

**Module APIs**

- [app.copy_to_clipboard](#appcopy_to_clipboard)
- [app.get_blogmark_bookmarklet](#appget_blogmark_bookmarklet)
- [app.get_data_paths](#appget_data_paths)
- [app.get_default_project_path](#appget_default_project_path)
- [app.get_system_language](#appget_system_language)
- [app.get_title_bar_metrics](#appget_title_bar_metrics)
- [app.notify_renderer_ready](#appnotify_renderer_ready)
- [app.open_folder](#appopen_folder)
- [app.read_project_metadata](#appread_project_metadata)
- [app.select_folder](#appselect_folder)
- [app.set_preview_post_target](#appset_preview_post_target)
- [app.show_item_in_folder](#appshow_item_in_folder)
- [app.trigger_menu_action](#apptrigger_menu_action)

### app.copy_to_clipboard

Copy text to the system clipboard.

**Parameters**

- text (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.app.copy_to_clipboard("value")
```

### app.get_blogmark_bookmarklet

Return the Blogmark bookmarklet JavaScript source.

**Parameters**

- None

**Response specification**

- Return type: `string`

**Example response**

```lua
"value"
```

**Example call**

```lua
local result = bds.app.get_blogmark_bookmarklet()
```

### app.get_data_paths

Return filesystem paths for the current application and project data.

**Parameters**

- None

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.app.get_default_project_path()
```

### app.get_system_language

Return the current UI locale (the server-side UI language setting, falling back to the OS locale when unset).

**Parameters**

- None

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.app.get_system_language()
```

### app.get_title_bar_metrics

Return desktop title bar inset metrics when available.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.app.get_title_bar_metrics()
```

### app.notify_renderer_ready

Notify the host application that the renderer is ready.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.app.notify_renderer_ready()
```

### app.open_folder

Open a folder in the system file manager.

**Parameters**

- folder_path (string, required)

**Response specification**

- Return type: `string`

**Example response**

```lua
"value"
```

**Example call**

```lua
local result = bds.app.open_folder("/Users/me/Sites/example")
```

### app.read_project_metadata

Read project metadata from a project folder path.

**Parameters**

- folder_path (string, required)

**Response specification**

- Return type: `ProjectMetadata | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectMetadata`

**Example response**

```lua
nil  -- or
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.app.read_project_metadata("/Users/me/Sites/example")
```

### app.select_folder

Show the native folder picker and return the chosen path.

**Parameters**

- title (string, optional)

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.app.select_folder("Example Title")
```

### app.set_preview_post_target

Set the current preview-post target used by desktop integrations.

**Parameters**

- post_id (string, optional)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.app.set_preview_post_target("id-1")
```

### app.show_item_in_folder

Reveal a file or folder in the system file manager.

**Parameters**

- item_path (string, required)

**Response specification**

- Return type: `nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil
```

**Example call**

```lua
local result = bds.app.show_item_in_folder("/Users/me/Sites/example/output/index.html")
```

### app.trigger_menu_action

Trigger a native menu action by action id.

**Parameters**

- action (string, required)

**Response specification**

- Return type: `nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil
```

**Example call**

```lua
local result = bds.app.trigger_menu_action("save")
```

[↑ Back to Table of contents](#table-of-contents)

## projects

**Module APIs**

- [projects.create](#projectscreate)
- [projects.delete](#projectsdelete)
- [projects.delete_with_data](#projectsdelete_with_data)
- [projects.get](#projectsget)
- [projects.get_all](#projectsget_all)
- [projects.get_active](#projectsget_active)
- [projects.set_active](#projectsset_active)
- [projects.update](#projectsupdate)

### projects.create

Create a project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `ProjectData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  slug = "value",
  description = nil,
  data_path = nil,
  is_active = true,
  created_at = 1,
  updated_at = 1
}
```

**Example call**

```lua
local result = bds.projects.create({title = "Example Title"})
```

### projects.delete

Delete a project by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.projects.delete("id-1")
```

### projects.delete_with_data

Delete a project by id and remove its project directory.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.projects.delete_with_data("id-1")
```

### projects.get

Fetch one project by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ProjectData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  slug = "value",
  description = nil,
  data_path = nil,
  is_active = true,
  created_at = 1,
  updated_at = 1
}
```

**Example call**

```lua
local result = bds.projects.get("id-1")
```

### projects.get_all

Fetch all projects.

**Parameters**

- None

**Response specification**

- Return type: `ProjectData[]`
- Data structures: `ProjectData`

**Example response**

```lua
{
  {
    id = "value",
    name = "value",
    slug = "value",
    description = nil,
    data_path = nil,
    is_active = true,
    created_at = 1,
    updated_at = 1
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  slug = "value",
  description = nil,
  data_path = nil,
  is_active = true,
  created_at = 1,
  updated_at = 1
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  slug = "value",
  description = nil,
  data_path = nil,
  is_active = true,
  created_at = 1,
  updated_at = 1
}
```

**Example call**

```lua
local result = bds.projects.set_active("id-1")
```

### projects.update

Update a project by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `ProjectData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  slug = "value",
  description = nil,
  data_path = nil,
  is_active = true,
  created_at = 1,
  updated_at = 1
}
```

**Example call**

```lua
local result = bds.projects.update("id-1", {title = "Example Title"})
```

[↑ Back to Table of contents](#table-of-contents)

## posts

**Module APIs**

- [posts.create](#postscreate)
- [posts.update](#postsupdate)
- [posts.delete](#postsdelete)
- [posts.discard](#postsdiscard)
- [posts.filter](#postsfilter)
- [posts.generate_unique_slug](#postsgenerate_unique_slug)
- [posts.get](#postsget)
- [posts.get_all](#postsget_all)
- [posts.get_by_slug](#postsget_by_slug)
- [posts.get_by_status](#postsget_by_status)
- [posts.get_by_year_month](#postsget_by_year_month)
- [posts.get_categories](#postsget_categories)
- [posts.get_categories_with_counts](#postsget_categories_with_counts)
- [posts.get_dashboard_stats](#postsget_dashboard_stats)
- [posts.get_linked_by](#postsget_linked_by)
- [posts.get_links_to](#postsget_links_to)
- [posts.get_preview_url](#postsget_preview_url)
- [posts.get_tags](#postsget_tags)
- [posts.get_tags_with_counts](#postsget_tags_with_counts)
- [posts.get_translation](#postsget_translation)
- [posts.get_translations](#postsget_translations)
- [posts.has_published_version](#postshas_published_version)
- [posts.is_slug_available](#postsis_slug_available)
- [posts.publish](#postspublish)
- [posts.publish_translation](#postspublish_translation)
- [posts.rebuild_from_files](#postsrebuild_from_files)
- [posts.rebuild_links](#postsrebuild_links)
- [posts.reindex_text](#postsreindex_text)
- [posts.search](#postssearch)

### posts.create

Create a post in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `PostData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.create({title = "Example Title"})
```

### posts.update

Update a post by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `PostData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.update("id-1", {title = "Example Title"})
```

### posts.delete

Delete a post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.posts.delete("id-1")
```

### posts.discard

Discard unpublished post changes and restore the last published version from disk.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `PostData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.discard("id-1")
```

### posts.filter

Filter posts using status, tags, categories, language, year, month, or date range fields.

**Parameters**

- filters (table, required)

**Response specification**

- Return type: `PostData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    title = "value",
    slug = "value",
    status = "value",
    language = nil,
    tags = {
      "value"
    },
    categories = {
      "value"
    },
    backlinks = {
      {
        key = "value"
      }
    },
    links_to = {
      {
        key = "value"
      }
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.filter({status = "draft"})
```

### posts.generate_unique_slug

Generate a unique slug from a title, optionally excluding one post id.

**Parameters**

- title (string, required)
- exclude_post_id (string, optional)

**Response specification**

- Return type: `string`

**Example response**

```lua
"value"
```

**Example call**

```lua
local result = bds.posts.generate_unique_slug("Example Title", "value")
```

### posts.get

Fetch one post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `PostData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.get("id-1")
```

### posts.get_all

Fetch all posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `PostData[]`
- Data structures: `PostData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    title = "value",
    slug = "value",
    status = "value",
    language = nil,
    tags = {
      "value"
    },
    categories = {
      "value"
    },
    backlinks = {
      {
        key = "value"
      }
    },
    links_to = {
      {
        key = "value"
      }
    }
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.get_by_slug("example-slug")
```

### posts.get_by_status

Fetch posts filtered by a specific status.

**Parameters**

- status (string, required)

**Response specification**

- Return type: `PostData[]`
- Data structures: `PostData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    title = "value",
    slug = "value",
    status = "value",
    language = nil,
    tags = {
      "value"
    },
    categories = {
      "value"
    },
    backlinks = {
      {
        key = "value"
      }
    },
    links_to = {
      {
        key = "value"
      }
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.get_by_status("draft")
```

### posts.get_by_year_month

Get post counts grouped by year and month.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.posts.get_by_year_month()
```

### posts.get_categories

Get category names used by posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

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

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.posts.get_categories_with_counts()
```

### posts.get_dashboard_stats

Return aggregate post dashboard counts for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.posts.get_dashboard_stats()
```

### posts.get_linked_by

Return posts that link to the given post.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.posts.get_linked_by("id-1")
```

### posts.get_links_to

Return posts linked from the given post.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.posts.get_links_to("id-1")
```

### posts.get_preview_url

Return the local preview URL for a post, optionally with draft and language query parameters.

**Parameters**

- post_id (string, required)
- options (table, optional)

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.posts.get_preview_url("id-1", {})
```

### posts.get_tags

Get tag names used by posts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

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

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.posts.get_translation("id-1", "en")
```

### posts.get_translations

Get all translations for a post.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.posts.get_translations("id-1")
```

### posts.has_published_version

Check whether a post has a published version.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.posts.has_published_version("id-1")
```

### posts.is_slug_available

Return whether a slug is available in the current project, optionally excluding one post id.

**Parameters**

- slug (string, required)
- exclude_post_id (string, optional)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.posts.is_slug_available("example-slug", "value")
```

### posts.publish

Publish a post by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `PostData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  title = "value",
  slug = "value",
  status = "value",
  language = nil,
  tags = {
    "value"
  },
  categories = {
    "value"
  },
  backlinks = {
    {
      key = "value"
    }
  },
  links_to = {
    {
      key = "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.publish("id-1")
```

### posts.publish_translation

Publish one translation of a post by language.

**Parameters**

- post_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.posts.publish_translation("id-1", "en")
```

### posts.rebuild_from_files

Rebuild post records from published files.

**Parameters**

- None

**Response specification**

- Return type: `PostData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    title = "value",
    slug = "value",
    status = "value",
    language = nil,
    tags = {
      "value"
    },
    categories = {
      "value"
    },
    backlinks = {
      {
        key = "value"
      }
    },
    links_to = {
      {
        key = "value"
      }
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.rebuild_from_files()
```

### posts.rebuild_links

Rebuild the post link graph for the current project.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.posts.rebuild_links()
```

### posts.reindex_text

Reindex post and media search text for the current project.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `PostData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    title = "value",
    slug = "value",
    status = "value",
    language = nil,
    tags = {
      "value"
    },
    categories = {
      "value"
    },
    backlinks = {
      {
        key = "value"
      }
    },
    links_to = {
      {
        key = "value"
      }
    }
  }
}
```

**Example call**

```lua
local result = bds.posts.search("example query")
```

[↑ Back to Table of contents](#table-of-contents)

## media

**Module APIs**

- [media.delete_translation](#mediadelete_translation)
- [media.filter](#mediafilter)
- [media.import](#mediaimport)
- [media.get_by_year_month](#mediaget_by_year_month)
- [media.get_file_path](#mediaget_file_path)
- [media.update](#mediaupdate)
- [media.delete](#mediadelete)
- [media.get](#mediaget)
- [media.get_all](#mediaget_all)
- [media.get_tags](#mediaget_tags)
- [media.get_tags_with_counts](#mediaget_tags_with_counts)
- [media.get_thumbnail](#mediaget_thumbnail)
- [media.get_translation](#mediaget_translation)
- [media.get_translations](#mediaget_translations)
- [media.get_url](#mediaget_url)
- [media.rebuild_from_files](#mediarebuild_from_files)
- [media.regenerate_missing_thumbnails](#mediaregenerate_missing_thumbnails)
- [media.regenerate_thumbnails](#mediaregenerate_thumbnails)
- [media.reindex_text](#mediareindex_text)
- [media.replace_file](#mediareplace_file)
- [media.search](#mediasearch)
- [media.upsert_translation](#mediaupsert_translation)

### media.delete_translation

Delete a media translation by language.

**Parameters**

- media_id (string, required)
- language (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.media.delete_translation("id-1", "en")
```

### media.filter

Filter media using year, month, tags, language, or date range fields.

**Parameters**

- filters (table, required)

**Response specification**

- Return type: `MediaData[]`
- Data structures: `MediaData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    original_name = "value",
    mime_type = "value",
    file_path = "value",
    title = nil,
    alt = nil,
    caption = nil,
    tags = {
      "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.media.filter({status = "draft"})
```

### media.import

Import media into the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `MediaData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  original_name = "value",
  mime_type = "value",
  file_path = "value",
  title = nil,
  alt = nil,
  caption = nil,
  tags = {
    "value"
  }
}
```

**Example call**

```lua
local result = bds.media.import({title = "Example Title"})
```

### media.get_by_year_month

Get media counts grouped by year and month.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.media.get_by_year_month()
```

### media.get_file_path

Return the absolute file path for a media item.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.media.get_file_path("id-1")
```

### media.update

Update media metadata by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `MediaData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  original_name = "value",
  mime_type = "value",
  file_path = "value",
  title = nil,
  alt = nil,
  caption = nil,
  tags = {
    "value"
  }
}
```

**Example call**

```lua
local result = bds.media.update("id-1", {title = "Example Title"})
```

### media.delete

Delete a media item by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.media.delete("id-1")
```

### media.get

Fetch one media item by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `MediaData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  original_name = "value",
  mime_type = "value",
  file_path = "value",
  title = nil,
  alt = nil,
  caption = nil,
  tags = {
    "value"
  }
}
```

**Example call**

```lua
local result = bds.media.get("id-1")
```

### media.get_all

Fetch all media in the current project.

**Parameters**

- None

**Response specification**

- Return type: `MediaData[]`
- Data structures: `MediaData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    original_name = "value",
    mime_type = "value",
    file_path = "value",
    title = nil,
    alt = nil,
    caption = nil,
    tags = {
      "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.media.get_all()
```

### media.get_tags

Return tag names used by media in the current project.

**Parameters**

- None

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

**Example call**

```lua
local result = bds.media.get_tags()
```

### media.get_tags_with_counts

Return media tags with usage counts.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.media.get_tags_with_counts()
```

### media.get_thumbnail

Return a media thumbnail as a data URL for the requested size.

**Parameters**

- media_id (string, required)
- size (string, optional)

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.media.get_thumbnail("id-1", "value")
```

### media.get_translation

Return one media translation by language.

**Parameters**

- media_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.media.get_translation("id-1", "en")
```

### media.get_translations

Return all translations for a media item.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.media.get_translations("id-1")
```

### media.get_url

Return the project-relative public URL path for a media item.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `string | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
"value"
```

**Example call**

```lua
local result = bds.media.get_url("id-1")
```

### media.rebuild_from_files

Rebuild media records from sidecar files on disk.

**Parameters**

- None

**Response specification**

- Return type: `MediaData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    original_name = "value",
    mime_type = "value",
    file_path = "value",
    title = nil,
    alt = nil,
    caption = nil,
    tags = {
      "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.media.rebuild_from_files()
```

### media.regenerate_missing_thumbnails

Generate thumbnails for media items that are missing them.

**Parameters**

- None

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.media.regenerate_missing_thumbnails()
```

### media.regenerate_thumbnails

Regenerate all thumbnails for one media item.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.media.regenerate_thumbnails("id-1")
```

### media.reindex_text

Reindex post and media search text for the current project.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.media.reindex_text()
```

### media.replace_file

Replace the binary file behind an existing media item.

**Parameters**

- media_id (string, required)
- source_path (string, required)

**Response specification**

- Return type: `MediaData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  original_name = "value",
  mime_type = "value",
  file_path = "value",
  title = nil,
  alt = nil,
  caption = nil,
  tags = {
    "value"
  }
}
```

**Example call**

```lua
local result = bds.media.replace_file("id-1", "/Users/me/Pictures/example.jpg")
```

### media.search

Search media by free-text query.

**Parameters**

- query (string, required)

**Response specification**

- Return type: `MediaData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `MediaData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    original_name = "value",
    mime_type = "value",
    file_path = "value",
    title = nil,
    alt = nil,
    caption = nil,
    tags = {
      "value"
    }
  }
}
```

**Example call**

```lua
local result = bds.media.search("example query")
```

### media.upsert_translation

Create or update a media translation.

**Parameters**

- media_id (string, required)
- language (string, required)
- data (table, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.media.upsert_translation("id-1", "en", {title = "Example Title"})
```

[↑ Back to Table of contents](#table-of-contents)

## scripts

**Module APIs**

- [scripts.create](#scriptscreate)
- [scripts.update](#scriptsupdate)
- [scripts.delete](#scriptsdelete)
- [scripts.get](#scriptsget)
- [scripts.get_all](#scriptsget_all)
- [scripts.publish](#scriptspublish)
- [scripts.rebuild_from_files](#scriptsrebuild_from_files)

### scripts.create

Create a script in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `ScriptData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ScriptData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  entrypoint = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.scripts.create({title = "Example Title"})
```

### scripts.update

Update a script by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `ScriptData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ScriptData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  entrypoint = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.scripts.update("id-1", {title = "Example Title"})
```

### scripts.delete

Delete a script by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.scripts.delete("id-1")
```

### scripts.get

Fetch one script by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `ScriptData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ScriptData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  entrypoint = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.scripts.get("id-1")
```

### scripts.get_all

Fetch all scripts in the current project.

**Parameters**

- None

**Response specification**

- Return type: `ScriptData[]`
- Data structures: `ScriptData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    slug = "value",
    title = "value",
    kind = "value",
    entrypoint = "value",
    enabled = true,
    status = "value"
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ScriptData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  entrypoint = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.scripts.publish("id-1")
```

### scripts.rebuild_from_files

Rebuild script records from published files.

**Parameters**

- None

**Response specification**

- Return type: `ScriptData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ScriptData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    slug = "value",
    title = "value",
    kind = "value",
    entrypoint = "value",
    enabled = true,
    status = "value"
  }
}
```

**Example call**

```lua
local result = bds.scripts.rebuild_from_files()
```

[↑ Back to Table of contents](#table-of-contents)

## templates

**Module APIs**

- [templates.create](#templatescreate)
- [templates.update](#templatesupdate)
- [templates.delete](#templatesdelete)
- [templates.get](#templatesget)
- [templates.get_all](#templatesget_all)
- [templates.get_enabled_by_kind](#templatesget_enabled_by_kind)
- [templates.publish](#templatespublish)
- [templates.rebuild_from_files](#templatesrebuild_from_files)
- [templates.validate](#templatesvalidate)

### templates.create

Create a template in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `TemplateData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TemplateData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.templates.create({title = "Example Title"})
```

### templates.update

Update a template by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `TemplateData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TemplateData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.templates.update("id-1", {title = "Example Title"})
```

### templates.delete

Delete a template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.templates.delete("id-1")
```

### templates.get

Fetch one template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TemplateData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TemplateData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.templates.get("id-1")
```

### templates.get_all

Fetch all templates in the current project.

**Parameters**

- None

**Response specification**

- Return type: `TemplateData[]`
- Data structures: `TemplateData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    slug = "value",
    title = "value",
    kind = "value",
    enabled = true,
    status = "value"
  }
}
```

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
- Data structures: `TemplateData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    slug = "value",
    title = "value",
    kind = "value",
    enabled = true,
    status = "value"
  }
}
```

**Example call**

```lua
local result = bds.templates.get_enabled_by_kind("post")
```

### templates.publish

Publish a template by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TemplateData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TemplateData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  slug = "value",
  title = "value",
  kind = "value",
  enabled = true,
  status = "value"
}
```

**Example call**

```lua
local result = bds.templates.publish("id-1")
```

### templates.rebuild_from_files

Rebuild template records from published files.

**Parameters**

- None

**Response specification**

- Return type: `TemplateData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TemplateData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    slug = "value",
    title = "value",
    kind = "value",
    enabled = true,
    status = "value"
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ValidationResult`

**Example response**

```lua
nil  -- or
{
  valid = true,
  errors = {
    "value"
  }
}
```

**Example call**

```lua
local result = bds.templates.validate("Example content")
```

[↑ Back to Table of contents](#table-of-contents)

## meta

**Module APIs**

- [meta.add_category](#metaadd_category)
- [meta.add_tag](#metaadd_tag)
- [meta.clear_publishing_preferences](#metaclear_publishing_preferences)
- [meta.get_categories](#metaget_categories)
- [meta.get_project_metadata](#metaget_project_metadata)
- [meta.get_publishing_preferences](#metaget_publishing_preferences)
- [meta.get_tags](#metaget_tags)
- [meta.remove_category](#metaremove_category)
- [meta.remove_tag](#metaremove_tag)
- [meta.set_project_metadata](#metaset_project_metadata)
- [meta.set_publishing_preferences](#metaset_publishing_preferences)
- [meta.sync_on_startup](#metasync_on_startup)
- [meta.update_project_metadata](#metaupdate_project_metadata)

### meta.add_category

Add a category to the current project.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `ProjectMetadata | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectMetadata`

**Example response**

```lua
nil  -- or
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.meta.add_category("Example Name")
```

### meta.add_tag

Add a tag record to the current project if it does not already exist.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

**Example call**

```lua
local result = bds.meta.add_tag("Example Name")
```

### meta.clear_publishing_preferences

Reset publishing preferences to defaults.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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

**Example response**

```lua
{
  "value"
}
```

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
- Data structures: `ProjectMetadata`

**Example response**

```lua
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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

**Example response**

```lua
{
  "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectMetadata`

**Example response**

```lua
nil  -- or
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.meta.remove_category("Example Name")
```

### meta.remove_tag

Remove a tag record from the current project by name.

**Parameters**

- name (string, required)

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

**Example call**

```lua
local result = bds.meta.remove_tag("Example Name")
```

### meta.set_project_metadata

Replace project metadata fields for the current project.

**Parameters**

- updates (table, required)

**Response specification**

- Return type: `ProjectMetadata | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectMetadata`

**Example response**

```lua
nil  -- or
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.meta.set_project_metadata({name = "Updated Blog"})
```

### meta.set_publishing_preferences

Set publishing preferences for the current project.

**Parameters**

- prefs (table, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.meta.set_publishing_preferences({provider = "filesystem"})
```

### meta.sync_on_startup

Synchronize startup metadata state and return tags, categories, and project metadata.

**Parameters**

- None

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.meta.sync_on_startup()
```

### meta.update_project_metadata

Update metadata for the current project. Keys omitted from updates keep their current values.

**Parameters**

- updates (table, required)

**Response specification**

- Return type: `ProjectMetadata | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `ProjectMetadata`

**Example response**

```lua
nil  -- or
{
  name = "value",
  description = nil,
  public_url = nil,
  main_language = nil,
  default_author = nil,
  categories = {
    "value"
  },
  blog_languages = {
    "value"
  },
  publishing_preferences = {
    key = "value"
  }
}
```

**Example call**

```lua
local result = bds.meta.update_project_metadata({name = "Updated Blog"})
```

[↑ Back to Table of contents](#table-of-contents)

## tags

**Module APIs**

- [tags.create](#tagscreate)
- [tags.update](#tagsupdate)
- [tags.delete](#tagsdelete)
- [tags.get](#tagsget)
- [tags.get_all](#tagsget_all)
- [tags.get_by_name](#tagsget_by_name)
- [tags.get_posts_with_tag](#tagsget_posts_with_tag)
- [tags.get_with_counts](#tagsget_with_counts)
- [tags.merge](#tagsmerge)
- [tags.rename](#tagsrename)
- [tags.sync_from_posts](#tagssync_from_posts)

### tags.create

Create a tag in the current project.

**Parameters**

- data (table, required)

**Response specification**

- Return type: `TagData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  name = "value",
  color = nil,
  post_template_slug = nil
}
```

**Example call**

```lua
local result = bds.tags.create({title = "Example Title"})
```

### tags.update

Update a tag by id.

**Parameters**

- id (string, required)
- data (table, required)

**Response specification**

- Return type: `TagData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  name = "value",
  color = nil,
  post_template_slug = nil
}
```

**Example call**

```lua
local result = bds.tags.update("id-1", {title = "Example Title"})
```

### tags.delete

Delete a tag by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.tags.delete("id-1")
```

### tags.get

Fetch one tag by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `TagData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  name = "value",
  color = nil,
  post_template_slug = nil
}
```

**Example call**

```lua
local result = bds.tags.get("id-1")
```

### tags.get_all

Fetch all tags in the current project.

**Parameters**

- None

**Response specification**

- Return type: `TagData[]`
- Data structures: `TagData`

**Example response**

```lua
{
  {
    id = "value",
    project_id = "value",
    name = "value",
    color = nil,
    post_template_slug = nil
  }
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  name = "value",
  color = nil,
  post_template_slug = nil
}
```

**Example call**

```lua
local result = bds.tags.get_by_name("Example Name")
```

### tags.get_posts_with_tag

Get post ids using a specific tag.

**Parameters**

- tag_id (string, required)

**Response specification**

- Return type: `string[]`

**Example response**

```lua
{
  "value"
}
```

**Example call**

```lua
local result = bds.tags.get_posts_with_tag("id-1")
```

### tags.get_with_counts

Fetch tags with usage counts.

**Parameters**

- None

**Response specification**

- Return type: `table[]`

**Example response**

```lua
{
  {
    key = "value"
  }
}
```

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

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.tags.merge({}, "id-1")
```

### tags.rename

Rename a tag by id.

**Parameters**

- id (string, required)
- new_name (string, required)

**Response specification**

- Return type: `TagData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  project_id = "value",
  name = "value",
  color = nil,
  post_template_slug = nil
}
```

**Example call**

```lua
local result = bds.tags.rename("id-1", "value")
```

### tags.sync_from_posts

Sync tag records from post tags.

**Parameters**

- None

**Response specification**

- Return type: `TagData[] | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TagData`

**Example response**

```lua
nil  -- or
{
  {
    id = "value",
    project_id = "value",
    name = "value",
    color = nil,
    post_template_slug = nil
  }
}
```

**Example call**

```lua
local result = bds.tags.sync_from_posts()
```

[↑ Back to Table of contents](#table-of-contents)

## tasks

**Module APIs**

- [tasks.cancel](#taskscancel)
- [tasks.clear_completed](#tasksclear_completed)
- [tasks.get](#tasksget)
- [tasks.get_all](#tasksget_all)
- [tasks.get_running](#tasksget_running)
- [tasks.status_snapshot](#tasksstatus_snapshot)

### tasks.cancel

Cancel a task by id.

**Parameters**

- id (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

**Example call**

```lua
local result = bds.tasks.cancel("id-1")
```

### tasks.clear_completed

Clear completed tasks from the in-memory task list.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TaskData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  status = "value",
  progress = nil,
  message = nil
}
```

**Example call**

```lua
local result = bds.tasks.get("id-1")
```

### tasks.get_all

Fetch all tasks currently tracked by the task manager.

**Parameters**

- None

**Response specification**

- Return type: `TaskData[]`
- Data structures: `TaskData`

**Example response**

```lua
{
  {
    id = "value",
    name = "value",
    status = "value",
    progress = nil,
    message = nil
  }
}
```

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
- Data structures: `TaskData`

**Example response**

```lua
{
  {
    id = "value",
    name = "value",
    status = "value",
    progress = nil,
    message = nil
  }
}
```

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
- Data structures: `TaskStatus`

**Example response**

```lua
{
  active_count = 1,
  running_count = 1,
  pending_count = 1,
  tasks = {
    {
      id = "value",
      name = "value",
      status = "value",
      progress = nil,
      message = nil
    }
  }
}
```

**Example call**

```lua
local result = bds.tasks.status_snapshot()
```

[↑ Back to Table of contents](#table-of-contents)

## sync

**Module APIs**

- [sync.check_availability](#synccheck_availability)
- [sync.commit_all](#synccommit_all)
- [sync.fetch](#syncfetch)
- [sync.get_history](#syncget_history)
- [sync.get_remote_state](#syncget_remote_state)
- [sync.get_repo_state](#syncget_repo_state)
- [sync.get_status](#syncget_status)
- [sync.pull](#syncpull)
- [sync.push](#syncpush)

### sync.check_availability

Return whether Git is available on the current machine.

**Parameters**

- None

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.sync.commit_all("Update content")
```

### sync.fetch

Fetch remote Git refs for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.sync.push()
```

[↑ Back to Table of contents](#table-of-contents)

## publish

**Module APIs**

- [publish.upload_site](#publishupload_site)

### publish.upload_site

Upload the rendered site using the provided publishing credentials.

**Parameters**

- credentials (table, required)

**Response specification**

- Return type: `TaskData | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.
- Data structures: `TaskData`

**Example response**

```lua
nil  -- or
{
  id = "value",
  name = "value",
  status = "value",
  progress = nil,
  message = nil
}
```

**Example call**

```lua
local result = bds.publish.upload_site({provider = "sftp"})
```

[↑ Back to Table of contents](#table-of-contents)

## chat

**Module APIs**

- [chat.analyze_media_image](#chatanalyze_media_image)
- [chat.analyze_post](#chatanalyze_post)
- [chat.detect_media_language](#chatdetect_media_language)
- [chat.detect_post_language](#chatdetect_post_language)
- [chat.translate_media_metadata](#chattranslate_media_metadata)
- [chat.translate_post](#chattranslate_post)

### chat.analyze_media_image

Analyze a media image using the configured AI runtime.

**Parameters**

- media_id (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.analyze_media_image("id-1")
```

### chat.analyze_post

Analyze a post using the configured AI runtime.

**Parameters**

- post_id (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.analyze_post("id-1")
```

### chat.detect_media_language

Detect the language of media metadata.

**Parameters**

- title (string, required)
- alt (string, optional)
- caption (string, optional)

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.detect_media_language("Example Title", "value", "value")
```

### chat.detect_post_language

Detect the language of post title and content.

**Parameters**

- title (string, required)
- content (string, required)

**Response specification**

- Return type: `table`

**Example response**

```lua
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.detect_post_language("Example Title", "Example content")
```

### chat.translate_media_metadata

Translate media metadata and persist the translation.

**Parameters**

- media_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.translate_media_metadata("id-1", "en")
```

### chat.translate_post

Translate a post and persist the translation.

**Parameters**

- post_id (string, required)
- language (string, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.chat.translate_post("id-1", "en")
```

[↑ Back to Table of contents](#table-of-contents)

## embeddings

**Module APIs**

- [embeddings.compute_similarities](#embeddingscompute_similarities)
- [embeddings.dismiss_pair](#embeddingsdismiss_pair)
- [embeddings.find_duplicates](#embeddingsfind_duplicates)
- [embeddings.find_similar](#embeddingsfind_similar)
- [embeddings.get_progress](#embeddingsget_progress)
- [embeddings.index_unindexed_posts](#embeddingsindex_unindexed_posts)
- [embeddings.suggest_tags](#embeddingssuggest_tags)

### embeddings.compute_similarities

Compute similarity scores from one source post to target posts.

**Parameters**

- post_id (string, required)
- target_ids (table, required)

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.embeddings.compute_similarities("id-1", {"id-2", "id-3"})
```

### embeddings.dismiss_pair

Dismiss a duplicate candidate pair.

**Parameters**

- post_id_a (string, required)
- post_id_b (string, required)

**Response specification**

- Return type: `boolean`

**Example response**

```lua
true
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.embeddings.find_similar("id-1", 10)
```

### embeddings.get_progress

Get embedding index progress for the current project.

**Parameters**

- None

**Response specification**

- Return type: `table | nil`
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

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
- Nullability: Returns `nil` when no matching value exists or the operation cannot produce a value.

**Example response**

```lua
nil  -- or
{
  key = "value"
}
```

**Example call**

```lua
local result = bds.embeddings.suggest_tags("id-1", {"draft"})
```

[↑ Back to Table of contents](#table-of-contents)


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
