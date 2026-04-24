defmodule BDS.Desktop.ShellCommandsTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellCommands

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Preview))
    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Publishing))

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-shell-commands-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf(temp_dir)
      _ = BDS.Preview.stop_preview("default")
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

    assert result.kind == "open_editor"
    assert result.route == "translation_validation"
    assert result.payload.summary.missing_count == 1
    post_id = post.id
    assert [%{"language" => "de", "post_id" => ^post_id}] = result.payload.missing
  end

  test "reindex_text queues a tracked background task for the active project", %{project: project} do
    assert {:ok, result} = ShellCommands.execute("reindex_text")

    assert result.kind == "task_queued"
    assert result.action == "reindex_text"
    assert result.project_id == project.id
    assert is_binary(result.task_id)

    assert task = BDS.Tasks.get_task(result.task_id)
    assert task.group_name == "Search"
    assert wait_for_task(result.task_id, &(&1.status in [:completed, :failed])).status == :completed
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
end
