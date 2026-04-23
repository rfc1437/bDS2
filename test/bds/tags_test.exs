defmodule BDS.TagsTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-tags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Tags", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "create_tag persists the row and rewrites meta/tags.json sorted by name", %{project: project, temp_dir: temp_dir} do
    assert {:ok, zebra} = BDS.Tags.create_tag(%{project_id: project.id, name: "Zebra", color: "#000000"})
    assert {:ok, alpha} = BDS.Tags.create_tag(%{project_id: project.id, name: "Alpha"})

    assert zebra.name == "Zebra"
    assert zebra.color == "#000000"
    assert alpha.color == nil

    tags_path = Path.join([temp_dir, "meta", "tags.json"])
    assert File.exists?(tags_path)

    assert %{"tags" => [%{"name" => "Alpha"}, %{"color" => "#000000", "name" => "Zebra"}]} =
             Jason.decode!(File.read!(tags_path))
  end

  test "create_tag rejects case-insensitive duplicates per project", %{project: project} do
    assert {:ok, _tag} = BDS.Tags.create_tag(%{project_id: project.id, name: "Elixir"})
    assert {:error, changeset} = BDS.Tags.create_tag(%{project_id: project.id, name: "elixir"})
    assert "has already been taken" in errors_on(changeset).name
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
