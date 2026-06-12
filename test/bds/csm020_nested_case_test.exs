defmodule BDS.CSM020NestedCaseTest do
  use ExUnit.Case, async: false

  alias BDS.ImportDefinitions
  alias BDS.Templates

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm020-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} =
      BDS.Projects.create_project(%{name: "CSM-020 Test", data_path: temp_dir})

    %{project: project, temp_dir: temp_dir}
  end

  describe "ImportDefinitions.delete_definition/1 uses with" do
    test "returns {:ok, :deleted} on success", %{project: project} do
      {:ok, definition} =
        ImportDefinitions.create_definition(%{
          project_id: project.id,
          name: "test",
          wxr_file_path: "/tmp/test.xml"
        })

      assert {:ok, :deleted} = ImportDefinitions.delete_definition(definition.id)
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} =
               ImportDefinitions.delete_definition(Ecto.UUID.generate())
    end

    test "source code uses with instead of nested case" do
      source = File.read!("lib/bds/import_definitions.ex")
      [func_source] = Regex.scan(~r/def delete_definition.*?(?=\n  def |\n  @|\nend)/s, source)

      refute func_source |> List.first() |> String.contains?("|> case do"),
             "delete_definition should not pipe into case"
    end
  end

  describe "Templates.update_template/2 uses with" do
    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Templates.update_template(Ecto.UUID.generate(), %{})
    end

    test "updates title successfully", %{project: project} do
      {:ok, template} =
        Templates.create_template(%{
          project_id: project.id,
          title: "Original",
          kind: :post,
          content: "<p>test</p>"
        })

      assert {:ok, updated} =
               Templates.update_template(template.id, %{title: "Updated"})

      assert updated.title == "Updated"
    end

    test "source code uses with instead of deeply nested case" do
      source = File.read!("lib/bds/templates.ex")

      refute Regex.match?(
               ~r/def update_template.*?case Repo\.get.*?case transaction_result/s,
               source
             ),
             "update_template should not have nested case blocks"
    end
  end

  describe "Publishing.update_job/2 uses with" do
    test "source code uses with instead of case" do
      source = File.read!("lib/bds/publishing.ex")

      [func_source] =
        Regex.scan(~r/defp update_job\(job_id, attrs\).*?(?=\n  defp |\nend)/s, source)

      assert func_source |> List.first() |> String.contains?("with"),
             "update_job should use with"

      refute func_source |> List.first() |> String.contains?("case Repo.get"),
             "update_job should not use case Repo.get"
    end
  end
end
