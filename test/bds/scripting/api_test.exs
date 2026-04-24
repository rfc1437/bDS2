defmodule BDS.Scripting.ApiTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

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
end
