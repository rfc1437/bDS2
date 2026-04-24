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

  test "publish_script writes a lua file with frontmatter and clears draft content", %{
    project: project,
    temp_dir: temp_dir
  } do
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
    assert contents =~ ~r/created_at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\n/
    assert contents =~ ~r/updated_at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\n/
    assert contents =~ "\n---\nfunction main() return 'ok' end\n"
    refute File.exists?(full_path <> ".tmp")
  end

  test "update_script bumps version and reopens a published script when content changes", %{
    project: project
  } do
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

  test "delete_script removes the published file and database row", %{
    project: project,
    temp_dir: temp_dir
  } do
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

  test "rebuild_scripts_from_files recreates published scripts from disk", %{
    project: project,
    temp_dir: temp_dir
  } do
    script_dir = Path.join(temp_dir, "scripts")
    File.mkdir_p!(script_dir)

    file_path = Path.join(script_dir, "recovered.lua")

    File.write!(
      file_path,
      [
        "---",
        "id: script-from-file",
        "slug: recovered",
        "title: Recovered Script",
        "kind: utility",
        "entrypoint: main",
        "enabled: true",
        "version: 4",
        "created_at: 1970-01-01T00:00:00.301Z",
        "updated_at: 1970-01-01T00:00:00.404Z",
        "---",
        "function main() return 'restored' end",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, scripts} = BDS.Scripts.rebuild_scripts_from_files(project.id)
    assert length(scripts) == 1

    [script] = Repo.all(Script)
    assert script.id == "script-from-file"
    assert script.slug == "recovered"
    assert script.title == "Recovered Script"
    assert script.kind == :utility
    assert script.entrypoint == "main"
    assert script.enabled == true
    assert script.version == 4
    assert script.status == :published
    assert script.file_path == "scripts/recovered.lua"
    assert script.content == nil
    assert script.created_at == 301
    assert script.updated_at == 404
  end
end
