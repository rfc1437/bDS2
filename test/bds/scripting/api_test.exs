defmodule BDS.Scripting.ApiTest do
  use ExUnit.Case, async: false

  @tiny_png_1 Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a6sAAAAASUVORK5CYII=")
  @tiny_png_2 Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z/C/HwAF/gL+qJNmNwAAAABJRU5ErkJggg==")

  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Templates.Template

  defmodule StubRuntime do
    def generate(_endpoint, request, _opts) do
      message_content = get_in(request, [:messages, Access.at(1), "content"])

      content =
        if is_binary(message_content) and String.contains?(message_content, "Detect the language") do
          Jason.encode!(%{"language_code" => "de"})
        else
          Jason.encode!(%{"title" => "Stub", "alt" => "Stub alt", "caption" => "Stub caption"})
        end

      {:ok,
       %{
         content: content,
         json: Jason.decode!(content),
         tool_calls: [],
         usage: %{input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 0}
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-scripting-api-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Scripting API", data_path: temp_dir})

    %{project: project}
  end

  test "project capabilities expose current backend data through explicit bds namespaces", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Capability Post",
               content: "Body",
               language: "en",
               tags: ["elixir"],
               categories: ["article"]
             })

    assert {:ok, _published_post} = BDS.Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    source = [
      "function main()",
      "  local meta = bds.meta.get_project_metadata()",
      "  local fetched = bds.posts.get_by_slug('capability-post')",
      "  local tags = bds.tags.get_all()",
      "  return {",
      "    project_name = meta.name,",
      "    post_title = fetched.title,",
      "    tag_count = #tags",
      "  }",
      "end"
    ]
    |> Enum.join("\n")

    assert {:ok, %{"project_name" => "Scripting API", "post_title" => "Capability Post", "tag_count" => 1}} =
             BDS.Scripting.execute_project_script(project.id, source, "main")
  end

  test "macro execution uses explicit project capabilities and degrades failures to empty output", %{
    project: project
  } do
    source = [
      "function render()",
      "  local meta = bds.meta.get_project_metadata()",
      "  return '<strong>' .. meta.name .. '</strong>'",
      "end"
    ]
    |> Enum.join("\n")

    assert {:ok, "<strong>Scripting API</strong>"} =
             BDS.Scripting.execute_macro(project.id, source, [])

    bad_source = "function render() error('boom') end"

    assert {:ok, ""} = BDS.Scripting.execute_macro(project.id, bad_source, [])
  end

  test "project scripting exposes project, post, script, template, metadata, and task namespaces", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Lua Coverage",
               content: "Body",
               language: "en"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, _created_script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Existing Utility",
               kind: :utility,
               content: "function main() return true end"
             })

    assert {:ok, _created_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Existing Template",
               kind: :post,
               content: "<article>{{ post.title }}</article>"
             })

    source =
      [
        "function main()",
        "  local active = bds.projects.get_active()",
        "  local projects = bds.projects.get_all()",
        "  local created = bds.scripts.create({ title = 'Lua Utility', kind = 'utility', content = 'function main() return 42 end' })",
        "  local templates = bds.templates.get_all()",
        "  local created_template = bds.templates.create({ title = 'Lua Template', kind = 'partial', content = '<p>Lua</p>' })",
        "  local updated_meta = bds.meta.update_project_metadata({ description = 'Updated from Lua' })",
        "  local task_status = bds.tasks.status_snapshot()",
        "  local fetched = bds.posts.get_by_slug('lua-coverage')",
        "  return {",
        "    active_project = active.name,",
        "    project_count = #projects,",
        "    created_script_title = created.title,",
        "    existing_script_title = bds.scripts.get(created.id).title,",
        "    existing_template_title = templates[1].title,",
        "    created_template_kind = created_template.kind,",
        "    meta_description = updated_meta.description,",
        "    task_active_count = task_status.active_count,",
        "    published_post_slug = fetched.slug,",
        "    published_post_status = bds.posts.get(fetched.id).status",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} =
             BDS.Scripting.execute_project_script(project.id, source, "main", [],
               copy_to_clipboard: fn _text -> true end,
               title_bar_metrics: fn -> %{macos_left_inset: 64} end,
               notify_renderer_ready: fn -> true end,
               open_folder: fn _path -> "" end,
               show_item_in_folder: fn _path -> :ok end,
               trigger_menu_action: fn _action -> :ok end
             )

    assert %{
             "active_project" => "Scripting API",
             "created_script_title" => "Lua Utility",
             "existing_script_title" => "Lua Utility",
             "existing_template_title" => "Existing Template",
             "created_template_kind" => "partial",
             "meta_description" => "Updated from Lua",
             "task_active_count" => 0,
             "published_post_status" => "published"
           } = result

    assert result["project_count"] >= 1
    assert result["published_post_slug"] == published_post.slug

    assert %Script{title: "Lua Utility"} =
             Repo.get_by(Script, project_id: project.id, title: "Lua Utility")

    assert %Template{title: "Lua Template"} =
             Repo.get_by(Template, project_id: project.id, title: "Lua Template")
  end

  test "project scripting exposes remaining old-app compatibility namespaces", %{project: project} do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:airplane, %{url: "http://stub.local", model: "stub-model"})

    assert :ok = BDS.AI.set_airplane_mode(true)

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Embedding Source",
               content: "Guten Tag aus Berlin",
               language: "de"
             })

    source =
      [
        "function main()",
        "  local app = bds.app.get_system_language()",
        "  local data_paths = bds.app.get_data_paths()",
        "  local folder_meta = bds.app.read_project_metadata(data_paths.project)",
        "  local sync_available = bds.sync.check_availability()",
        "  local repo_state = bds.sync.get_repo_state()",
        "  local publish_job = bds.publish.upload_site({ ssh_host = 'example.test', ssh_user = 'deploy', ssh_remote_path = '/srv/www', ssh_mode = 'scp' })",
        "  local detect = bds.chat.detect_post_language('Hallo Welt', 'Guten Tag aus Berlin')",
        "  local progress = bds.embeddings.get_progress()",
        "  local similar = bds.embeddings.find_similar('" <> post.id <> "', 5)",
        "  return {",
        "    system_language = app,",
        "    project_path = data_paths.project,",
        "    folder_name = folder_meta.name,",
        "    sync_available = sync_available,",
        "    repo_initialized = repo_state.is_initialized,",
        "    publish_job_id = publish_job.id,",
        "    detected_language = detect.language,",
        "    progress_total = progress.total,",
        "    similar_count = #similar",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} =
             BDS.Scripting.execute_project_script(project.id, source, "main", [],
               ai_runtime: StubRuntime,
               publishing_uploader: fn _target, _files, _credentials -> :ok end
             )

    assert is_binary(result["system_language"])
    assert result["project_path"] == project.data_path
    assert result["folder_name"] == "Scripting API"
    assert is_boolean(result["sync_available"])
    assert result["repo_initialized"] == false
    assert is_binary(result["publish_job_id"])
    assert result["detected_language"] == "de"
    assert result["progress_total"] >= 1
    assert result["similar_count"] == 0
  end

  test "project scripting exposes project metadata, rebuild, and task listing helpers", %{
    project: project
  } do
    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Published Utility",
               kind: :utility,
               content: "function main() return 1 end"
             })

    assert {:ok, _published_script} = BDS.Scripts.publish_script(script.id)

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Published Post Template",
               kind: :post,
               content: "<article>{{ post.title }}</article>"
             })

    assert {:ok, _published_template} = BDS.Templates.publish_template(template.id)

    assert {:ok, running_task} =
             BDS.Tasks.register_external_task("preview build", %{
               group_id: "generation",
               group_name: "Generation"
             })

    on_exit(fn ->
      _ = BDS.Tasks.complete_task(running_task.id)
    end)

    source =
      [
        "function main()",
        "  local updated = bds.projects.update('" <> project.id <> "', { description = 'Updated through Lua' })",
        "  bds.meta.set_publishing_preferences({ ssh_host = 'example.test', ssh_user = 'deploy', ssh_remote_path = '/srv/www', ssh_mode = 'scp' })",
        "  local prefs = bds.meta.get_publishing_preferences()",
        "  local categories = bds.meta.get_categories()",
        "  local scripts = bds.scripts.rebuild_from_files()",
        "  local templates = bds.templates.rebuild_from_files()",
        "  local enabled_post_templates = bds.templates.get_enabled_by_kind('post')",
        "  local tasks = bds.tasks.get_all()",
        "  local running = bds.tasks.get_running()",
        "  bds.meta.clear_publishing_preferences()",
        "  local cleared = bds.meta.get_publishing_preferences()",
        "  return {",
        "    project_description = updated.description,",
        "    ssh_mode = prefs.ssh_mode,",
        "    category_count = #categories,",
        "    rebuilt_script_count = #scripts,",
        "    rebuilt_template_count = #templates,",
        "    enabled_post_template_count = #enabled_post_templates,",
        "    task_count = #tasks,",
        "    running_count = #running,",
        "    cleared_ssh_mode = cleared.ssh_mode",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} =
             BDS.Scripting.execute_project_script(project.id, source, "main", [],
               copy_to_clipboard: fn _text -> true end,
               title_bar_metrics: fn -> %{macos_left_inset: 64} end,
               notify_renderer_ready: fn -> true end,
               open_folder: fn _path -> "" end,
               show_item_in_folder: fn _path -> :ok end,
               trigger_menu_action: fn _action -> :ok end
             )

    assert result["project_description"] == "Updated through Lua"
    assert result["ssh_mode"] == "scp"
    assert result["category_count"] >= 1
    assert result["rebuilt_script_count"] >= 1
    assert result["rebuilt_template_count"] >= 1
    assert result["enabled_post_template_count"] >= 1
    assert result["task_count"] >= 1
    assert result["running_count"] >= 1
    assert result["cleared_ssh_mode"] == "scp"
  end

  test "project scripting exposes post, tag, and translation lookup helpers", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Lookup Post",
               excerpt: "Search me",
               content: "Elixir lookup body with tag coverage",
               language: "en",
               tags: ["elixir", "lua"],
               categories: ["article", "guide"]
             })

    assert {:ok, _published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, _translation} =
             BDS.Posts.upsert_post_translation(post.id, "de", %{
               title: "Nachschlagebeitrag",
               excerpt: "Suche mich",
               content: "Deutscher Inhalt"
             })

    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    source =
      [
        "function main()",
        "  local meta_tags = bds.meta.get_tags()",
        "  local with_counts = bds.tags.get_with_counts()",
        "  local tag_posts = bds.tags.get_posts_with_tag(bds.tags.get_by_name('elixir').id)",
        "  local post_tags = bds.posts.get_tags()",
        "  local post_tag_counts = bds.posts.get_tags_with_counts()",
        "  local post_categories = bds.posts.get_categories()",
        "  local post_category_counts = bds.posts.get_categories_with_counts()",
        "  local translations = bds.posts.get_translations('" <> post.id <> "')",
        "  local translation = bds.posts.get_translation('" <> post.id <> "', 'de')",
        "  local published = bds.posts.has_published_version('" <> post.id <> "')",
        "  local search = bds.posts.search('lookup')",
        "  return {",
        "    meta_tag_count = #meta_tags,",
        "    tag_with_count = with_counts[1].count,",
        "    tag_post_count = #tag_posts,",
        "    post_tag_count = #post_tags,",
        "    post_tag_count_rows = #post_tag_counts,",
        "    category_count = #post_categories,",
        "    category_count_rows = #post_category_counts,",
        "    translation_count = #translations,",
        "    translation_title = translation.title,",
        "    has_published = published,",
        "    search_count = #search",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} = BDS.Scripting.execute_project_script(project.id, source, "main")

    assert result["meta_tag_count"] >= 2
    assert result["tag_with_count"] >= 1
    assert result["tag_post_count"] == 1
    assert result["post_tag_count"] >= 2
    assert result["post_tag_count_rows"] >= 2
    assert result["category_count"] >= 2
    assert result["category_count_rows"] >= 2
    assert result["translation_count"] == 1
    assert result["translation_title"] == "Nachschlagebeitrag"
    assert result["has_published"] == true
    assert result["search_count"] >= 1
  end

  test "project scripting exposes remaining post and media parity helpers", %{project: project} do
    media_source_path = write_binary_fixture(project.data_path, "image-a.png", @tiny_png_1)
    replacement_source_path = write_binary_fixture(project.data_path, "image-b.png", @tiny_png_2)

    assert {:ok, target_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Target Post",
               content: "Target body",
               language: "en",
               tags: ["target"],
               categories: ["reference"]
             })

    assert {:ok, _published_target} = BDS.Posts.publish_post(target_post.id)

    assert {:ok, source_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Source Post",
               excerpt: "Draft excerpt",
               content: "See [Target](/target-post) for more.",
               language: "en",
               tags: ["source", "featured"],
               categories: ["guide"]
             })

    assert {:ok, _published_source} = BDS.Posts.publish_post(source_post.id)

    assert {:ok, _source_translation} =
             BDS.Posts.upsert_post_translation(source_post.id, "de", %{
               title: "Quellbeitrag",
               excerpt: "Deutscher Auszug",
               content: "Siehe [Target](/target-post) fur mehr."
             })

    assert {:ok, _draft_source} =
             BDS.Posts.update_post(source_post.id, %{
               title: "Source Post Draft",
               excerpt: "Changed excerpt",
               content: "Changed body with [Target](/target-post)"
             })

    source =
      [
        "function main()",
        "  local function step(name, fn)",
        "    local ok, value = pcall(fn)",
        "    if not ok then error(name .. ': ' .. tostring(value)) end",
        "    return value",
        "  end",
        "  local function count(name, value)",
        "    local ok, length = pcall(function() return #value end)",
        "    if not ok then error(name .. ': ' .. tostring(length)) end",
        "    return length",
        "  end",
        "  local imported = step('media.import', function() return bds.media.import({ source_path = '" <> escape_lua_string(media_source_path) <> "', title = 'Imported Image', alt = 'Alt text', caption = 'Caption', tags = { 'gallery', 'cover' }, language = 'en' }) end)",
        "  local translation = step('media.upsert_translation', function() return bds.media.upsert_translation(imported.id, 'de', { title = 'Bild', alt = 'Alt de', caption = 'Beschriftung' }) end)",
        "  local fetched_translation = step('media.get_translation', function() return bds.media.get_translation(imported.id, 'de') end)",
        "  local translation_count = count('media.get_translations.count', step('media.get_translations', function() return bds.media.get_translations(imported.id) end))",
        "  local media_filter = step('media.filter', function() return bds.media.filter({ year = " <> Integer.to_string(Date.utc_today().year) <> ", tags = { 'gallery' } }) end)",
        "  local media_search = step('media.search', function() return bds.media.search('Imported') end)",
        "  local media_counts = step('media.get_by_year_month', function() return bds.media.get_by_year_month() end)",
        "  local media_tags = step('media.get_tags', function() return bds.media.get_tags() end)",
        "  local media_tag_counts = step('media.get_tags_with_counts', function() return bds.media.get_tags_with_counts() end)",
        "  local media_url = step('media.get_url', function() return bds.media.get_url(imported.id) end)",
        "  local media_file_path = step('media.get_file_path', function() return bds.media.get_file_path(imported.id) end)",
        "  local thumbnail = step('media.get_thumbnail', function() return bds.media.get_thumbnail(imported.id, 'small') end)",
        "  local regenerated = step('media.regenerate_thumbnails', function() return bds.media.regenerate_thumbnails(imported.id) end)",
        "  local missing = step('media.regenerate_missing_thumbnails', function() return bds.media.regenerate_missing_thumbnails() end)",
        "  local replaced = step('media.replace_file', function() return bds.media.replace_file(imported.id, '" <> escape_lua_string(replacement_source_path) <> "') end)",
        "  local rebuilt_media = step('media.rebuild_from_files', function() return bds.media.rebuild_from_files() end)",
        "  local media_reindexed = step('media.reindex_text', function() return bds.media.reindex_text() end)",
        "  local deleted_translation = step('media.delete_translation', function() return bds.media.delete_translation(imported.id, 'de') end)",
        "  local slug_available = step('posts.is_slug_available', function() return bds.posts.is_slug_available('brand-new-slug') end)",
        "  local unique_slug = step('posts.generate_unique_slug', function() return bds.posts.generate_unique_slug('Target Post') end)",
        "  local published = step('posts.get_by_status', function() return bds.posts.get_by_status('published') end)",
        "  local by_month = step('posts.get_by_year_month', function() return bds.posts.get_by_year_month() end)",
        "  local dashboard = step('posts.get_dashboard_stats', function() return bds.posts.get_dashboard_stats() end)",
        "  local filtered = step('posts.filter', function() return bds.posts.filter({ status = 'draft', tags = { 'source' } }) end)",
        "  local rebuilt_links_before = step('posts.get_links_to.before', function() return bds.posts.get_links_to('" <> source_post.id <> "') end)",
        "  step('posts.rebuild_links', function() return bds.posts.rebuild_links() end)",
        "  local links_to = step('posts.get_links_to.after', function() return bds.posts.get_links_to('" <> source_post.id <> "') end)",
        "  local linked_by = step('posts.get_linked_by', function() return bds.posts.get_linked_by('" <> target_post.id <> "') end)",
        "  local preview_url = step('posts.get_preview_url', function() return bds.posts.get_preview_url('" <> source_post.id <> "', { draft = true, lang = 'de' }) end)",
        "  local published_translation = step('posts.publish_translation', function() return bds.posts.publish_translation('" <> source_post.id <> "', 'de') end)",
        "  local discarded = step('posts.discard', function() return bds.posts.discard('" <> source_post.id <> "') end)",
        "  return {",
        "    translation_title = translation and translation.title or nil,",
        "    fetched_translation_title = fetched_translation and fetched_translation.title or nil,",
        "    translation_count = translation_count,",
        "    media_filter_count = count('media.filter.count', media_filter),",
        "    media_search_count = count('media.search.count', media_search),",
        "    media_counts_count = count('media.get_by_year_month.count', media_counts),",
        "    media_tags_count = count('media.get_tags.count', media_tags),",
        "    media_tag_row_count = count('media.get_tags_with_counts.count', media_tag_counts),",
        "    media_url = media_url,",
        "    media_file_path = media_file_path,",
        "    thumbnail_prefix = string.sub(thumbnail or '', 1, 22),",
        "    regenerated_small = regenerated and regenerated.small or nil,",
        "    regenerated_missing_processed = missing and missing.processed or nil,",
        "    replaced_title = replaced and replaced.title or nil,",
        "    rebuilt_media_count = count('media.rebuild_from_files.count', rebuilt_media),",
        "    media_reindexed = media_reindexed,",
        "    deleted_translation = deleted_translation,",
        "    slug_available = slug_available,",
        "    unique_slug = unique_slug,",
        "    published_count = count('posts.get_by_status.count', published),",
        "    by_month_count = count('posts.get_by_year_month.count', by_month),",
        "    dashboard_total = dashboard and dashboard.total_posts or nil,",
        "    filtered_count = count('posts.filter.count', filtered),",
        "    rebuilt_links_before_count = count('posts.get_links_to.before.count', rebuilt_links_before),",
        "    links_to_count = count('posts.get_links_to.after.count', links_to),",
        "    linked_by_count = count('posts.get_linked_by.count', linked_by),",
        "    preview_url = preview_url,",
        "    published_translation_language = published_translation and published_translation.language or nil,",
        "    discarded_title = discarded and discarded.title or nil,",
        "    discarded_status = discarded and discarded.status or nil",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} = BDS.Scripting.execute_project_script(project.id, source, "main")

    assert result["translation_title"] == "Bild"
    assert result["fetched_translation_title"] == "Bild"
    assert result["translation_count"] == 1
    assert result["media_filter_count"] >= 1
    assert result["media_search_count"] >= 1
    assert result["media_counts_count"] >= 1
    assert result["media_tags_count"] >= 2
    assert result["media_tag_row_count"] >= 2
    assert String.starts_with?(result["media_url"], "/media/")
    assert String.ends_with?(result["media_file_path"], ".png")
    assert String.starts_with?(result["thumbnail_prefix"], "data:image/webp;base64")
    assert is_binary(result["regenerated_small"])
    assert result["regenerated_missing_processed"] >= 1
    assert result["replaced_title"] == "Imported Image"
    assert result["rebuilt_media_count"] >= 1
    assert result["media_reindexed"] == true
    assert result["deleted_translation"] == true
    assert result["slug_available"] == true
    assert result["unique_slug"] == "target-post-2"
    assert result["published_count"] >= 1
    assert result["by_month_count"] >= 1
    assert result["dashboard_total"] >= 2
    assert result["filtered_count"] >= 1
    assert result["rebuilt_links_before_count"] >= 1
    assert result["links_to_count"] >= 1
    assert result["linked_by_count"] >= 1
    assert String.contains?(result["preview_url"], "draft=true")
    assert String.contains?(result["preview_url"], "lang=de")
    assert result["published_translation_language"] == "de"
    assert result["discarded_title"] == "Source Post Draft"
    assert result["discarded_status"] == "published"
  end

  test "project scripting exposes remaining app and metadata parity helpers", %{project: project} do
    sample_file_path = write_binary_fixture(project.data_path, "show-me.txt", "hello")

    source =
      [
        "function main()",
        "  local bookmarklet = bds.app.get_blogmark_bookmarklet()",
        "  local copied = bds.app.copy_to_clipboard('copied from lua')",
        "  local metrics = bds.app.get_title_bar_metrics()",
        "  local ready = bds.app.notify_renderer_ready()",
        "  bds.app.set_preview_post_target(nil)",
        "  local open_result = bds.app.open_folder('" <> escape_lua_string(project.data_path) <> "')",
        "  bds.app.show_item_in_folder('" <> escape_lua_string(sample_file_path) <> "')",
        "  bds.app.trigger_menu_action('new_post')",
        "  local startup = bds.meta.sync_on_startup()",
        "  return {",
        "    bookmarklet_prefix = string.sub(bookmarklet, 1, 19),",
        "    copied = copied,",
        "    metrics_type = metrics == nil and 'nil' or 'table',",
        "    ready = ready,",
        "    open_result = open_result,",
        "    startup_tags = #startup.tags,",
        "    startup_categories = #startup.categories,",
        "    startup_project_name = startup.project_metadata.name",
        "  }",
        "end"
      ]
      |> Enum.join("\n")

    assert {:ok, result} = BDS.Scripting.execute_project_script(project.id, source, "main")

    assert String.starts_with?(result["bookmarklet_prefix"], "javascript:(()=>{")
    assert result["copied"] == true
    assert result["metrics_type"] in ["nil", "table"]
    assert result["ready"] == true
    assert result["open_result"] == ""
    assert result["startup_tags"] >= 0
    assert result["startup_categories"] >= 1
    assert result["startup_project_name"] == "Scripting API"
  end

  defp write_binary_fixture(base_dir, name, contents) do
    path = Path.join(base_dir, name)
    File.write!(path, contents)
    path
  end

  defp escape_lua_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end
end
