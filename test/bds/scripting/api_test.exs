defmodule BDS.Scripting.ApiTest do
  use ExUnit.Case, async: false

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

    assert {:ok, result} = BDS.Scripting.execute_project_script(project.id, source, "main")

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

    assert {:ok, result} = BDS.Scripting.execute_project_script(project.id, source, "main")

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
end
