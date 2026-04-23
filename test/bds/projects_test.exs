defmodule BDS.ProjectsTest do
  use ExUnit.Case, async: false

  alias BDS.Projects.Project
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
  end

  test "create_project slugifies names, keeps new projects inactive, and deduplicates slugs" do
    assert {:ok, first} = BDS.Projects.create_project(%{name: "Föö Bär Blog", data_path: "/tmp/blog"})

    assert first.name == "Föö Bär Blog"
    assert first.slug == "foo-bar-blog"
    assert first.data_path == "/tmp/blog"
    assert first.is_active == false
    assert is_integer(first.created_at)
    assert is_integer(first.updated_at)

    assert {:ok, second} = BDS.Projects.create_project(%{name: "Föö Bär Blog"})
    assert second.slug == "foo-bar-blog-2"
    assert second.is_active == false
  end

  test "set_active_project clears the previous active project and activates the target" do
    assert {:ok, first} = BDS.Projects.create_project(%{name: "First"})
    assert {:ok, second} = BDS.Projects.create_project(%{name: "Second"})

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
