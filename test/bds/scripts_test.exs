defmodule BDS.ScriptsTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    {:ok, project} = BDS.Projects.create_project(%{name: "Scripts"})
    %{project: project}
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
end
