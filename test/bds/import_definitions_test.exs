defmodule BDS.ImportDefinitionsTest do
  use ExUnit.Case, async: false

  alias BDS.ImportDefinitions

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-import-definitions-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} =
      BDS.Projects.create_project(%{name: "Import Definitions", data_path: temp_dir})

    %{project: project, temp_dir: temp_dir}
  end

  test "get, update, and delete round-trip import definition editor state", %{
    project: project,
    temp_dir: temp_dir
  } do
    uploads_folder_path = Path.join(temp_dir, "uploads")
    wxr_file_path = Path.join(temp_dir, "legacy.xml")

    assert {:ok, definition} =
             ImportDefinitions.create_definition(%{
               project_id: project.id,
               name: "Legacy Import",
               wxr_file_path: wxr_file_path,
               uploads_folder_path: uploads_folder_path,
               last_analysis_result: Jason.encode!(%{site_info: %{title: "Legacy Blog"}})
             })

    fetched = ImportDefinitions.get_definition(definition.id)
    assert fetched.id == definition.id
    assert fetched.project_id == project.id
    assert fetched.name == "Legacy Import"
    assert fetched.wxr_file_path == wxr_file_path
    assert fetched.uploads_folder_path == uploads_folder_path
    assert fetched.last_analysis_result == Jason.encode!(%{site_info: %{title: "Legacy Blog"}})

    assert {:ok, updated} =
             ImportDefinitions.update_definition(definition.id, %{
               name: "Renamed Import",
               wxr_file_path: Path.join(temp_dir, "renamed.xml"),
               uploads_folder_path: Path.join(temp_dir, "renamed-uploads"),
               last_analysis_result: %{
                 site_info: %{title: "Renamed Blog"},
                 post_stats: %{new_count: 2}
               }
             })

    assert updated.name == "Renamed Import"
    assert updated.wxr_file_path == Path.join(temp_dir, "renamed.xml")
    assert updated.uploads_folder_path == Path.join(temp_dir, "renamed-uploads")

    assert updated.last_analysis_result ==
             Jason.encode!(%{site_info: %{title: "Renamed Blog"}, post_stats: %{new_count: 2}})

    assert [%{id: listed_id, title: "Renamed Import"}] =
             ImportDefinitions.list_definitions(project.id)

    assert listed_id == definition.id

    assert {:ok, :deleted} = ImportDefinitions.delete_definition(definition.id)
    assert ImportDefinitions.get_definition(definition.id) == nil
  end
end
