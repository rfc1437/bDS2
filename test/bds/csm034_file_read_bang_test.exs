defmodule BDS.CSM034FileReadBangTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  describe "source-level: no File.read! or File.write! in affected files" do
    test "preview_assets.ex has no File.read!" do
      source = File.read!("lib/bds/preview_assets.ex")
      refute source =~ "File.read!", "preview_assets.ex should use File.read, not File.read!"
    end

    test "templates.ex has no File.read!" do
      source = File.read!("lib/bds/templates.ex")
      refute source =~ "File.read!", "templates.ex should use File.read, not File.read!"
    end

    test "templates.ex has no File.write!" do
      source = File.read!("lib/bds/templates.ex")
      refute source =~ "File.write!", "templates.ex should use File.write, not File.write!"
    end

    test "release_packaging.ex has no File.read! or File.write!" do
      source = File.read!("lib/bds/release_packaging.ex")
      refute source =~ "File.read!", "release_packaging.ex should use File.read, not File.read!"
      refute source =~ "File.write!", "release_packaging.ex should use File.write, not File.write!"
    end
  end

  describe "preview_assets.generated_outputs/0 handles read errors" do
    test "returns results for readable files, skips unreadable ones" do
      outputs = BDS.PreviewAssets.generated_outputs()
      assert is_list(outputs)
      assert Enum.all?(outputs, fn {path, body} -> is_binary(path) and is_binary(body) end)
    end
  end

  describe "templates file error handling" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir = Path.join(System.tmp_dir!(), "bds-csm034-#{System.unique_integer([:positive])}")
      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} = BDS.Projects.create_project(%{name: "CSM034", data_path: temp_dir})
      %{project: project, temp_dir: temp_dir}
    end

    test "rebuild skips unreadable template files without crashing", %{
      project: project,
      temp_dir: temp_dir
    } do
      templates_dir = Path.join(temp_dir, "templates")
      File.mkdir_p!(templates_dir)

      File.write!(Path.join(templates_dir, "good.liquid"), """
      ---
      slug: good
      kind: post
      title: Good Template
      ---
      <p>{{ content }}</p>
      """)

      File.write!(Path.join(templates_dir, "bad.liquid"), "no frontmatter here")

      assert {:ok, templates} = BDS.Templates.rebuild_templates_from_files(project.id)
      assert length(templates) == 1
      assert hd(templates).slug == "good"
    end

    test "sync_template_from_file returns error when file is deleted", %{
      project: project,
      temp_dir: temp_dir
    } do
      templates_dir = Path.join(temp_dir, "templates")
      File.mkdir_p!(templates_dir)

      path = Path.join(templates_dir, "ephemeral.liquid")

      File.write!(path, """
      ---
      slug: ephemeral
      kind: post
      title: Ephemeral
      ---
      <p>{{ content }}</p>
      """)

      {:ok, _templates} = BDS.Templates.rebuild_templates_from_files(project.id)

      template =
        BDS.Repo.one(
          from(t in BDS.Templates.Template,
            where: t.project_id == ^project.id and t.slug == "ephemeral"
          )
        )

      File.rm!(path)

      assert {:error, :not_found} = BDS.Templates.sync_template_from_file(template.id)
    end

    test "import_orphan_template_file returns error for missing file", %{project: project} do
      assert {:error, :not_found} =
               BDS.Templates.import_orphan_template_file(project.id, "templates/ghost.liquid")
    end
  end
end
