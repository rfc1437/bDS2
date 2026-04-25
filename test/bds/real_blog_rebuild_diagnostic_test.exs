defmodule BDS.RealBlogRebuildDiagnosticTest do
  use ExUnit.Case, async: false

  @real_blog_path System.get_env("BDS_REAL_BLOG_PATH")
  @moduletag timeout: :infinity

  if is_binary(@real_blog_path) and @real_blog_path != "" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo, ownership_timeout: 600_000)

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
  else
    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "rebuilds posts from the external real blog path" do
    end

    @tag skip: "BDS_REAL_BLOG_PATH not set"
    test "rebuilds media from the external real blog path" do
    end
  end
end