defmodule BDS.ProjectsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Templates.Template

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_root = Path.join(System.tmp_dir!(), "bds-projects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_root)

    on_exit(fn -> File.rm_rf(temp_root) end)

    %{temp_root: temp_root}
  end

  test "create_project slugifies names, keeps new projects inactive, and deduplicates slugs", %{
    temp_root: temp_root
  } do
    first_dir = Path.join(temp_root, "first")
    second_dir = Path.join(temp_root, "second")
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)

    assert {:ok, first} =
             BDS.Projects.create_project(%{name: "Föö Bär Blog", data_path: first_dir})

    assert first.name == "Föö Bär Blog"
    assert first.slug == "foo-bar-blog"
    assert first.data_path == first_dir
    assert first.is_active == false
    assert is_integer(first.created_at)
    assert is_integer(first.updated_at)

    assert {:ok, second} =
             BDS.Projects.create_project(%{name: "Föö Bär Blog", data_path: second_dir})

    assert second.slug == "foo-bar-blog-2"
    assert second.is_active == false
  end

  test "create_project installs starter templates into the project data directory", %{
    temp_root: temp_root
  } do
    temp_dir = Path.join(temp_root, "starter")
    File.mkdir_p!(temp_dir)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Starter Blog", data_path: temp_dir})

    assert File.exists?(Path.join([temp_dir, "templates", "single-post.liquid"]))
    assert File.exists?(Path.join([temp_dir, "templates", "post-list.liquid"]))
    assert File.exists?(Path.join([temp_dir, "templates", "not-found.liquid"]))
    assert File.exists?(Path.join([temp_dir, "templates", "partials", "head.liquid"]))
    assert File.exists?(Path.join([temp_dir, "templates", "partials", "menu-items.liquid"]))
    assert File.exists?(Path.join([temp_dir, "templates", "macros", "gallery.liquid"]))

    starter_slugs =
      Repo.all(
        from template in Template,
          where: template.project_id == ^project.id,
          select: {template.slug, template.kind}
      )

    assert {"single-post", :post} in starter_slugs
    assert {"post-list", :list} in starter_slugs
    assert {"not-found", :not_found} in starter_slugs
  end

  test "starter template installation is idempotent for existing top-level templates", %{
    temp_root: temp_root
  } do
    temp_dir = Path.join(temp_root, "idempotent-starter")
    File.mkdir_p!(temp_dir)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Starter Blog", data_path: temp_dir})

    template_path = Path.join([temp_dir, "templates", "single-post.liquid"])
    original_contents = File.read!(template_path)
    assert {:ok, %{fields: original_fields}} = BDS.Frontmatter.parse_document(original_contents)
    assert is_binary(original_fields["id"])

    assert :ok = BDS.StarterTemplates.install(project)

    reinstalled_contents = File.read!(template_path)
    assert reinstalled_contents == original_contents

    assert {:ok, %{fields: reinstalled_fields}} =
             BDS.Frontmatter.parse_document(reinstalled_contents)

    assert reinstalled_fields["id"] == original_fields["id"]
  end

  test "set_active_project clears the previous active project and activates the target", %{
    temp_root: temp_root
  } do
    first_dir = Path.join(temp_root, "active-first")
    second_dir = Path.join(temp_root, "active-second")
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)

    assert {:ok, first} = BDS.Projects.create_project(%{name: "First", data_path: first_dir})
    assert {:ok, second} = BDS.Projects.create_project(%{name: "Second", data_path: second_dir})

    assert {:ok, active_first} = BDS.Projects.set_active_project(first.id)
    assert active_first.is_active == true

    assert {:ok, active_second} = BDS.Projects.set_active_project(second.id)
    assert active_second.is_active == true

    refetched_first = BDS.Projects.get_project!(first.id)
    refetched_second = BDS.Projects.get_project!(second.id)

    assert refetched_first.is_active == false
    assert refetched_second.is_active == true
    assert Enum.count(BDS.Projects.list_projects(), & &1.is_active) == 1
  end

  test "ensure_default_project creates the default project once and keeps it active" do
    Repo.delete_all(Project)

    assert {:ok, default_project} = BDS.Projects.ensure_default_project()
    assert default_project.id == "default"
    assert default_project.name == "My Blog"
    assert default_project.slug == "my-blog"
    assert default_project.is_active == true

    assert {:ok, same_project} = BDS.Projects.ensure_default_project()
    assert same_project.id == default_project.id
    assert Repo.aggregate(Project, :count, :id) == 1
  end
end
