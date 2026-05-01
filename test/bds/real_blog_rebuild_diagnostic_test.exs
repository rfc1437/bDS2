defmodule BDS.RealBlogRebuildDiagnosticTest do
  use ExUnit.Case, async: false

  @real_blog_path System.get_env("BDS_REAL_BLOG_PATH")
  @moduletag timeout: :infinity

  if is_binary(@real_blog_path) and @real_blog_path != "" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo, ownership_timeout: 600_000)
      Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

      now = BDS.Persistence.now_ms()
      unique = Integer.to_string(System.unique_integer([:positive]))

      project =
        %BDS.Projects.Project{}
        |> BDS.Projects.Project.changeset(%{
          id: "real-blog-#{unique}",
          name: "Real Blog Diagnostic",
          slug: "real-blog-diagnostic-#{unique}",
          data_path: Path.expand(@real_blog_path),
          created_at: now,
          updated_at: now,
          is_active: false
        })
        |> BDS.Repo.insert!()

      %{project: project}
    end

    test "rebuilds posts from the external real blog path", %{project: project} do
      assert {:ok, _posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
    end

    test "rebuilds media from the external real blog path", %{project: project} do
      assert {:ok, _media} = BDS.Maintenance.rebuild_from_filesystem(project.id, "media")
    end

    test "shell rebuild task rebuilds posts from the external real blog path", %{project: project} do
      :ok = BDS.Tasks.clear_finished()
      assert {:ok, _active} = BDS.Projects.set_active_project(project.id)

      assert {:ok, result} = BDS.Desktop.ShellCommands.execute("rebuild_database")
      assert result.kind == "task_queued"

      task =
        wait_for_named_task(
          "Rebuild Posts From Files",
          &(&1.status in [:completed, :failed]),
          600_000
        )

      assert task.status == :completed
    end

    test "rebuilds posts from the external real blog path twice in the same project", %{
      project: project
    } do
      assert {:ok, _posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
      assert {:ok, _posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
    end

    defp wait_for_named_task(_name, _matcher, timeout) when timeout <= 0 do
      flunk("named task did not reach expected state")
    end

    defp wait_for_named_task(name, matcher, timeout) do
      task = Enum.find(BDS.Tasks.list_tasks(), &(&1.name == name))

      if task && matcher.(task) do
        task
      else
        Process.sleep(100)
        wait_for_named_task(name, matcher, timeout - 100)
      end
    end
  else
    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "rebuilds posts from the external real blog path" do
    end

    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "rebuilds media from the external real blog path" do
    end

    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "shell rebuild task rebuilds posts from the external real blog path" do
    end

    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "rebuilds posts from the external real blog path twice in the same project" do
    end
  end
end
