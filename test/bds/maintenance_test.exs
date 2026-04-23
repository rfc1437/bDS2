defmodule BDS.MaintenanceTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-maintenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Maintenance", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "rebuild_from_filesystem dispatches to posts, media, scripts, and templates rebuilders", %{project: project, temp_dir: temp_dir} do
    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "dispatch-post.md"),
      [
        "---",
        "id: dispatch-post",
        "title: Dispatch Post",
        "slug: dispatch-post",
        "status: published",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "published_at: 1712016000",
        "tags:",
        "categories:",
        "---",
        "Body",
        ""
      ]
      |> Enum.join("\n")
    )

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "asset.txt"), "hello media")

    File.write!(
      Path.join(media_dir, "asset.txt.meta"),
      [
        "id: dispatch-media",
        "original_name: original.txt",
        "mime_type: text/plain",
        "size: 11",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "tags:",
        ""
      ]
      |> Enum.join("\n")
    )

    template_dir = Path.join(temp_dir, "templates")
    File.mkdir_p!(template_dir)
    File.write!(
      Path.join(template_dir, "dispatch-view.liquid"),
      [
        "---",
        "id: dispatch-template",
        "slug: dispatch-view",
        "title: Dispatch View",
        "kind: list",
        "enabled: true",
        "version: 1",
        "created_at: 101",
        "updated_at: 202",
        "---",
        "<section>Template</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    script_dir = Path.join(temp_dir, "scripts")
    File.mkdir_p!(script_dir)
    File.write!(
      Path.join(script_dir, "dispatch.lua"),
      [
        "---",
        "id: dispatch-script",
        "slug: dispatch",
        "title: Dispatch Script",
        "kind: utility",
        "entrypoint: main",
        "enabled: true",
        "version: 1",
        "created_at: 301",
        "updated_at: 404",
        "---",
        "function main() return true end",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, posts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "post")
    assert length(posts) == 1

    assert {:ok, media_items} = BDS.Maintenance.rebuild_from_filesystem(project.id, "media")
    assert length(media_items) == 1

    assert {:ok, scripts} = BDS.Maintenance.rebuild_from_filesystem(project.id, "script")
    assert length(scripts) == 1

    assert {:ok, templates} = BDS.Maintenance.rebuild_from_filesystem(project.id, "template")
    assert length(templates) == 1

    assert Repo.get(BDS.Posts.Post, "dispatch-post") != nil
    assert Repo.get(BDS.Media.Media, "dispatch-media") != nil
    assert Repo.get(BDS.Scripts.Script, "dispatch-script") != nil
    assert Repo.get(BDS.Templates.Template, "dispatch-template") != nil
  end

  test "rebuild_from_filesystem rejects unsupported entity types", %{project: project} do
    assert {:error, :unsupported_entity_type} = BDS.Maintenance.rebuild_from_filesystem(project.id, "unknown")
  end
end
