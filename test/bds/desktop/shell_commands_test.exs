defmodule BDS.Desktop.ShellCommandsTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellCommands

  defmodule SlowEmbeddingBackend do
    @behaviour BDS.Embeddings.Backend

    @impl true
    def model_info do
      BDS.Embeddings.Backends.InApp.model_info()
    end

    @impl true
    def embed(text, opts) do
      Process.sleep(10)
      BDS.Embeddings.Backends.InApp.embed(text, opts)
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Preview))
    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Publishing))
    :ok = BDS.Tasks.clear_finished()

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-commands-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf(temp_dir)
      _ = BDS.Preview.stop_preview("default")
      _ = BDS.Tasks.clear_finished()
    end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Shell Commands", data_path: temp_dir})
    {:ok, project} = BDS.Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  test "open_in_browser starts preview for the active project and returns a preview url", %{project: project} do
    assert {:ok, result} = ShellCommands.execute("open_in_browser")

    assert result.kind == "open_url"
    assert result.action == "open_in_browser"
    assert result.url == "http://127.0.0.1:4123/"
    assert result.project_id == project.id
  end

  test "validate_translations returns an editor payload with current translation gaps", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Hello",
               content: "World",
               language: "en"
             })

    assert {:ok, _published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, result} = ShellCommands.execute("validate_translations")

    assert result.kind == "task_queued"
    assert result.action == "validate_translations"
    assert is_binary(result.task_id)

    completed = wait_for_task(result.task_id, &(&1.status == :completed and is_map(&1.result)))

    assert completed.group_name == "Validation"
    assert completed.result.kind == "open_editor"
    assert completed.result.route == "translation_validation"
    assert completed.result.payload.summary.missing_count == 1
    post_id = post.id
    assert [%{"language" => "de", "post_id" => ^post_id}] = completed.result.payload.missing
  end

  test "validate_site queues a tracked validation task and returns the report as an editor payload" do
    assert {:ok, result} = ShellCommands.execute("validate_site")

    assert result.kind == "task_queued"
    assert result.action == "validate_site"
    assert is_binary(result.task_id)

    completed = wait_for_task(result.task_id, &(&1.status == :completed and is_map(&1.result)))

    assert completed.group_name == "Validation"
    assert is_binary(completed.message)
    assert String.starts_with?(completed.message, "Validation complete (")
    assert completed.result.kind == "open_editor"
    assert completed.result.route == "site_validation"
    assert is_map(completed.result.payload.summary)
    assert Map.has_key?(completed.result.payload, :missing_url_paths)
    assert Map.has_key?(completed.result.payload, :extra_url_paths)
    assert Map.has_key?(completed.result.payload, :updated_post_url_paths)
    assert Map.has_key?(completed.result.payload.summary, :expected_count)
    assert Map.has_key?(completed.result.payload.summary, :existing_count)
    assert Map.has_key?(completed.result.payload.summary, :updated_count)
  end

  test "metadata_diff queues a tracked maintenance task and returns the report as an editor payload" do
    assert {:ok, result} = ShellCommands.execute("metadata_diff")

    assert result.kind == "task_queued"
    assert result.action == "metadata_diff"
    assert is_binary(result.task_id)

    completed = wait_for_task(result.task_id, &(&1.status == :completed and is_map(&1.result)))

    assert completed.group_name == "Maintenance"
    assert completed.result.kind == "open_editor"
    assert completed.result.route == "metadata_diff"
    assert is_map(completed.result.payload.summary)
  end

  test "rebuild_posts_from_files rebuilds embeddings for published posts when semantic similarity is enabled", %{project: project} do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Filesystem Embedding Source",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)
    assert BDS.Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: published_post.id) != nil

    BDS.Repo.delete_all(BDS.Embeddings.Key)

    assert {:ok, result} = ShellCommands.execute("rebuild_posts_from_files")
    completed = wait_for_task(result.task_id, &(&1.status == :completed))

    assert completed.group_name == "Maintenance"
    assert BDS.Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: published_post.id) != nil
  end

  test "repair_metadata_diff exposes live in-task progress from the repair worker", %{project: project} do
    original = Application.get_env(:bds, :tasks, [])

    Application.put_env(
      :bds,
      :tasks,
      original
      |> Keyword.put(:max_concurrent, 1)
      |> Keyword.put(:progress_throttle_ms, 0)
    )

    on_exit(fn -> Application.put_env(:bds, :tasks, original) end)

    items =
      Enum.map(1..40, fn _index ->
        %{"entity_type" => "project", "entity_id" => project.id}
      end)

    assert {:ok, result} =
             ShellCommands.execute("repair_metadata_diff", %{
               "direction" => "file_to_db",
               "items" => items
             })

    progressed =
      wait_for_task(
        result.task_id,
        &(&1.status == :running and is_number(&1.progress) and &1.progress > 0.2 and &1.progress < 1.0),
        5_000
      )

    assert progressed.group_name == "Maintenance"
    assert String.contains?(progressed.message, "Repairing")
    assert String.contains?(progressed.message, "/")

    assert wait_for_task(result.task_id, &(&1.status == :completed and &1.progress == 1.0), 5_000).status ==
             :completed
  end

  test "find_duplicates queues a tracked embeddings task and returns the report as an editor payload" do
    assert {:ok, result} = ShellCommands.execute("find_duplicates")

    assert result.kind == "task_queued"
    assert result.action == "find_duplicates"
    assert is_binary(result.task_id)

    completed = wait_for_task(result.task_id, &(&1.status == :completed and is_map(&1.result)))

    assert completed.group_name == "Embeddings"
    assert completed.result.kind == "open_editor"
    assert completed.result.route == "find_duplicates"
    assert is_map(completed.result.payload.summary)
  end

  test "rebuild_embedding_index exposes live in-task progress while rebuilding posts", %{project: project} do
    original = Application.get_env(:bds, :tasks, [])
    original_embeddings = Application.get_env(:bds, :embeddings)

    Application.put_env(
      :bds,
      :tasks,
      original
      |> Keyword.put(:max_concurrent, 1)
      |> Keyword.put(:progress_throttle_ms, 0)
    )

    Application.put_env(:bds, :embeddings, backend: SlowEmbeddingBackend)

    on_exit(fn ->
      Application.put_env(:bds, :tasks, original)

      if is_nil(original_embeddings) do
        Application.delete_env(:bds, :embeddings)
      else
        Application.put_env(:bds, :embeddings, original_embeddings)
      end
    end)

    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    Enum.each(1..40, fn index ->
      assert {:ok, post} =
               BDS.Posts.create_post(%{
                 project_id: project.id,
                 title: "Embedding Progress #{index}",
                 content: "space rocket orbit mission galaxy #{index}",
                 language: "en"
               })

      assert {:ok, _published_post} = BDS.Posts.publish_post(post.id)
    end)

    BDS.Repo.delete_all(BDS.Embeddings.Key)

    assert {:ok, result} = ShellCommands.execute("rebuild_embedding_index")

    progressed =
      wait_for_task(
        result.task_id,
        &(&1.status == :running and is_number(&1.progress) and &1.progress > 0.0 and &1.progress < 1.0 and
            is_binary(&1.message) and String.contains?(&1.message, "/")),
        10_000
      )

    assert progressed.group_name == "Embeddings"
    assert String.contains?(progressed.message, "/")

    assert wait_for_task(result.task_id, &(&1.status == :completed and &1.progress == 1.0), 10_000).status ==
             :completed
  end

  test "rebuild_database fans out tracked maintenance tasks for the active project" do
    assert {:ok, result} = ShellCommands.execute("rebuild_database")

    assert result.kind == "task_queued"
    assert result.action == "rebuild_database"

    tasks = wait_for_tasks_by_name([
      "Rebuild Posts From Files",
      "Rebuild Media From Files",
      "Rebuild Scripts From Files",
      "Rebuild Templates From Files",
      "Rebuild Post Links",
      "Regenerate Missing Thumbnails",
      "Rebuild Embedding Index"
    ], &(&1.status == :completed))

    assert Enum.all?(tasks, &(&1.group_name == "Maintenance"))
    assert Enum.all?(tasks, &(&1.status == :completed))
  end

  test "rebuild_database does not run multiple rebuild writers at once", %{temp_dir: temp_dir} do
    original = Application.get_env(:bds, :tasks, [])

    Application.put_env(
      :bds,
      :tasks,
      original
      |> Keyword.put(:max_concurrent, 4)
      |> Keyword.put(:progress_throttle_ms, 0)
    )

    on_exit(fn -> Application.put_env(:bds, :tasks, original) end)

    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    scripts_dir = Path.join(temp_dir, "scripts")
    templates_dir = Path.join(temp_dir, "templates")

    File.mkdir_p!(posts_dir)
    File.mkdir_p!(media_dir)
    File.mkdir_p!(scripts_dir)
    File.mkdir_p!(templates_dir)

    Enum.each(1..80, fn index ->
      slug = "serial-post-#{index}"

      File.write!(
        Path.join(posts_dir, "#{slug}.md"),
        [
          "---",
          "id: #{slug}",
          "title: Serial Post #{index}",
          "slug: #{slug}",
          "status: published",
          "createdAt: 1711843200",
          "updatedAt: 1711929600",
          "publishedAt: 1712016000",
          "tags:",
          "categories:",
          "---",
          "Body #{index}",
          ""
        ]
        |> Enum.join("\n")
      )

      File.write!(Path.join(media_dir, "asset-#{index}.txt"), "asset #{index}")

      File.write!(
        Path.join(media_dir, "asset-#{index}.txt.meta"),
        [
          "id: serial-media-#{index}",
          "originalName: asset-#{index}.txt",
          "mimeType: text/plain",
          "size: 7",
          "createdAt: 1711843200",
          "updatedAt: 1711929600",
          "tags:",
          ""
        ]
        |> Enum.join("\n")
      )

      File.write!(
        Path.join(scripts_dir, "serial-script-#{index}.lua"),
        [
          "---",
          "id: serial-script-#{index}",
          "slug: serial-script-#{index}",
          "title: Serial Script #{index}",
          "kind: utility",
          "entrypoint: main",
          "enabled: true",
          "version: 1",
          "createdAt: 301",
          "updatedAt: 404",
          "---",
          "function main() return true end",
          ""
        ]
        |> Enum.join("\n")
      )

      File.write!(
        Path.join(templates_dir, "serial-template-#{index}.liquid"),
        [
          "---",
          "id: serial-template-#{index}",
          "slug: serial-template-#{index}",
          "title: Serial Template #{index}",
          "kind: list",
          "enabled: true",
          "version: 1",
          "createdAt: 101",
          "updatedAt: 202",
          "---",
          "<section>Template #{index}</section>",
          ""
        ]
        |> Enum.join("\n")
      )
    end)

    assert {:ok, _result} = ShellCommands.execute("rebuild_database")

    _posts_task =
      wait_for_named_task(
        "Rebuild Posts From Files",
        &(&1.status == :running and is_number(&1.progress) and &1.progress > 0.0 and &1.progress < 1.0),
        10_000
      )

    phase_one_tasks =
      BDS.Tasks.list_tasks()
      |> Enum.filter(&(&1.name in [
        "Rebuild Posts From Files",
        "Rebuild Media From Files",
        "Rebuild Scripts From Files",
        "Rebuild Templates From Files"
      ]))

    assert Enum.count(phase_one_tasks, &(&1.status == :running)) == 1

    assert Enum.find(phase_one_tasks, &(&1.status == :running)).name == "Rebuild Posts From Files"

    tasks = wait_for_tasks_by_name([
      "Rebuild Posts From Files",
      "Rebuild Media From Files",
      "Rebuild Scripts From Files",
      "Rebuild Templates From Files",
      "Rebuild Post Links",
      "Regenerate Missing Thumbnails",
      "Rebuild Embedding Index"
    ], &(&1.status == :completed), 20_000)

    assert Enum.all?(tasks, &(&1.status == :completed))
  end

  test "rebuild_database exposes live in-task progress for rebuild work", %{temp_dir: temp_dir} do
    original = Application.get_env(:bds, :tasks, [])

    Application.put_env(
      :bds,
      :tasks,
      original
      |> Keyword.put(:max_concurrent, 1)
      |> Keyword.put(:progress_throttle_ms, 0)
    )

    on_exit(fn -> Application.put_env(:bds, :tasks, original) end)

    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    Enum.each(1..80, fn index ->
      slug = "progress-post-#{index}"

      File.write!(
        Path.join(posts_dir, "#{slug}.md"),
        [
          "---",
          "id: #{slug}",
          "title: Progress Post #{index}",
          "slug: #{slug}",
          "status: published",
          "createdAt: 1711843200",
          "updatedAt: 1711929600",
          "publishedAt: 1712016000",
          "tags:",
          "categories:",
          "---",
          "Body #{index}",
          ""
        ]
        |> Enum.join("\n")
      )
    end)

    assert {:ok, result} = ShellCommands.execute("rebuild_database")
    assert result.kind == "task_queued"

    progressed =
      wait_for_named_task(
        "Rebuild Posts From Files",
        &(&1.status == :running and is_number(&1.progress) and &1.progress > 0.0 and &1.progress < 1.0),
        5_000
      )

    assert progressed.group_name == "Maintenance"
    assert String.contains?(progressed.message, "post")

    assert wait_for_task(progressed.id, &(&1.status == :completed and &1.progress == 1.0), 5_000).status ==
             :completed

    tasks = wait_for_tasks_by_name([
      "Rebuild Posts From Files",
      "Rebuild Media From Files",
      "Rebuild Scripts From Files",
      "Rebuild Templates From Files",
      "Rebuild Post Links",
      "Regenerate Missing Thumbnails",
      "Rebuild Embedding Index"
    ], &(&1.status == :completed), 20_000)

    assert Enum.all?(tasks, &(&1.status == :completed))
  end

  test "reindex_text queues a tracked background task for the active project", %{project: project} do
    assert {:ok, result} = ShellCommands.execute("reindex_text")

    assert result.kind == "task_queued"
    assert result.action == "reindex_text"
    assert result.project_id == project.id
    assert is_binary(result.task_id)
    assert is_binary(result.task_group_id)

    tasks = wait_for_tasks_by_name(["Reindex Search Text", "Reindex Media Search Text"], &(&1.status == :completed))

    assert Enum.all?(tasks, &(&1.group_name == "Search"))
    assert Enum.all?(tasks, &(&1.group_id == result.task_group_id))
    assert Enum.all?(tasks, &(&1.status == :completed))
  end

  test "missing project schema returns a command error instead of raising" do
    BDS.Repo.query!("DROP TABLE projects", [])

    assert {:error, %{message: message}} = ShellCommands.execute("open_in_browser")
    assert message =~ "Project database is not initialized"
  end

  defp wait_for_task(task_id, matcher, timeout \\ 2_000)

  defp wait_for_task(task_id, _matcher, timeout) when timeout <= 0 do
    BDS.Tasks.get_task(task_id)
  end

  defp wait_for_task(task_id, matcher, timeout) do
    task = BDS.Tasks.get_task(task_id)

    if task && matcher.(task) do
      task
    else
      Process.sleep(50)
      wait_for_task(task_id, matcher, timeout - 50)
    end
  end

  defp wait_for_tasks_by_name(names, matcher), do: wait_for_tasks_by_name(names, matcher, 2_000)

  defp wait_for_tasks_by_name(_names, _matcher, timeout) when timeout <= 0 do
    BDS.Tasks.list_tasks()
  end

  defp wait_for_tasks_by_name(names, matcher, timeout) do
    tasks = BDS.Tasks.list_tasks()
    matching_tasks = Enum.filter(tasks, &(&1.name in names))

    if Enum.all?(names, fn name -> Enum.any?(matching_tasks, &(&1.name == name)) end) and
         Enum.all?(matching_tasks, matcher) do
      matching_tasks
    else
      Process.sleep(50)
      wait_for_tasks_by_name(names, matcher, timeout - 50)
    end
  end

  defp wait_for_named_task(_name, _matcher, timeout) when timeout <= 0 do
    flunk("named task did not reach expected state")
  end

  defp wait_for_named_task(name, matcher, timeout) do
    task = Enum.find(BDS.Tasks.list_tasks(), &(&1.name == name))

    if task && matcher.(task) do
      task
    else
      Process.sleep(20)
      wait_for_named_task(name, matcher, timeout - 20)
    end
  end
end
