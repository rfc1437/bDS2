defmodule BDS.ScriptsTest do
  use ExUnit.Case, async: false

  alias BDS.Repo
  alias BDS.Scripts.Script

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-scripts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Scripts", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "create_script creates draft scripts with default entrypoints by kind", %{project: project} do
    assert {:ok, utility} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Importer",
               kind: :utility,
               content: "function main() end"
             })

    assert utility.slug == "importer"
    assert utility.entrypoint == "main"
    assert utility.status == :draft
    assert utility.enabled == true
    assert utility.version == 1
    assert utility.file_path == ""

    assert {:ok, macro_script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Render Card",
               kind: :macro,
               content: "function render() end"
             })

    assert macro_script.entrypoint == "render"
    assert macro_script.slug == "render-card"
  end

  test "publish_script writes a lua file with frontmatter and clears draft content", %{project: project, temp_dir: temp_dir} do
    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Process Feed",
               kind: :utility,
               content: "function main() return 'ok' end"
             })

    assert {:ok, published} = BDS.Scripts.publish_script(script.id)

    assert published.status == :published
    assert published.content == nil
    assert published.file_path == "scripts/process-feed.lua"

    full_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(full_path)

    contents = File.read!(full_path)
    assert contents =~ "---\nid: #{published.id}\n"
    assert contents =~ "slug: process-feed\n"
    assert contents =~ "title: Process Feed\n"
    assert contents =~ "kind: utility\n"
    assert contents =~ "entrypoint: main\n"
    assert contents =~ "enabled: true\n"
    assert contents =~ "version: 1\n"
    assert contents =~ "created_at: #{published.created_at}\n"
    assert contents =~ "updated_at: #{published.updated_at}\n"
    assert contents =~ "\n---\nfunction main() return 'ok' end\n"
  end

  test "update_script bumps version and reopens a published script when content changes", %{project: project} do
    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Render Card",
               kind: :macro,
               content: "function render() return 'v1' end"
             })

    assert {:ok, published} = BDS.Scripts.publish_script(script.id)
    assert published.status == :published

    assert {:ok, updated} =
             BDS.Scripts.update_script(script.id, %{
               content: "function render() return 'v2' end",
               enabled: false
             })

    assert updated.version == 2
    assert updated.status == :draft
    assert updated.enabled == false
    assert updated.file_path == "scripts/render-card.lua"
    assert updated.content == "function render() return 'v2' end"
    assert updated.updated_at >= published.updated_at
  end

  test "delete_script removes the published file and database row", %{project: project, temp_dir: temp_dir} do
    assert {:ok, script} =
             BDS.Scripts.create_script(%{
               project_id: project.id,
               title: "Cleanup",
               kind: :utility,
               content: "function main() return true end"
             })

    assert {:ok, published} = BDS.Scripts.publish_script(script.id)
    assert File.exists?(Path.join(temp_dir, published.file_path))

    assert {:ok, :deleted} = BDS.Scripts.delete_script(published.id)
    assert Repo.get(Script, published.id) == nil
    refute File.exists?(Path.join(temp_dir, published.file_path))
  end
end
