defmodule BDS.ProjectsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Metadata
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

  test "create_project leaves the project templates directory empty by default", %{
    temp_root: temp_root
  } do
    temp_dir = Path.join(temp_root, "starter")
    File.mkdir_p!(temp_dir)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Starter Blog", data_path: temp_dir})

    refute File.exists?(Path.join([temp_dir, "templates", "single-post.liquid"]))
    refute File.exists?(Path.join([temp_dir, "templates", "post-list.liquid"]))
    refute File.exists?(Path.join([temp_dir, "templates", "not-found.liquid"]))
    refute File.exists?(Path.join([temp_dir, "templates", "partials", "head.liquid"]))
    refute File.exists?(Path.join([temp_dir, "templates", "partials", "menu-items.liquid"]))
    refute File.exists?(Path.join([temp_dir, "templates", "macros", "gallery.liquid"]))

    starter_slugs =
      Repo.all(
        from template in Template,
          where: template.project_id == ^project.id,
          select: {template.slug, template.kind}
      )

    refute {"single-post", :post} in starter_slugs
    refute {"post-list", :list} in starter_slugs
    refute {"not-found", :not_found} in starter_slugs
  end

  test "create_project keeps committed project when template rebuild fails", %{
    temp_root: temp_root
  } do
    temp_dir = Path.join(temp_root, "broken-template-blog")
    templates_dir = Path.join(temp_dir, "templates")
    File.mkdir_p!(templates_dir)

    File.write!(
      Path.join(templates_dir, "broken.liquid"),
      "---\ntitle: Broken Template\nkind: post\n---\nBody"
    )

    assert_raise KeyError, fn ->
      BDS.Projects.create_project(%{name: "Broken Templates", data_path: temp_dir})
    end

    assert %Project{name: "Broken Templates"} =
             Repo.get_by(Project, data_path: temp_dir)
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

  test "project_cache_dir never falls back into the project data directory" do
    # Private app-internal artifacts (the embeddings index) must live under the
    # OS private app directory (macOS: ~/Library/Application Support/bds), never
    # inside priv/data/projects/<id> — leaving them in the project tree pollutes
    # the repository.
    saved = Application.get_env(:bds, :project_cache_root)
    Application.delete_env(:bds, :project_cache_root)
    on_exit(fn -> Application.put_env(:bds, :project_cache_root, saved) end)

    project_id = "fallback-#{System.unique_integer([:positive])}"
    cache_dir = BDS.Projects.project_cache_dir(project_id)

    data_dir = Path.expand("../../priv/data/projects/#{project_id}", __DIR__)
    refute cache_dir == data_dir
    refute String.starts_with?(cache_dir, Path.expand("../../priv/data", __DIR__))

    private_app_dir =
      case :filename.basedir(:user_config, "bds") do
        path when is_list(path) -> List.to_string(path)
        path -> path
      end
      |> Path.expand()

    assert String.starts_with?(cache_dir, private_app_dir)
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

  test "the default project's public content folder lives outside the repo and private dir" do
    Repo.delete_all(Project)

    assert {:ok, default_project} = BDS.Projects.ensure_default_project()

    data_dir = BDS.Projects.project_data_dir(default_project)

    # Public content must live under the per-user default content location,
    # never in the application repo (priv/data) nor the private app dir.
    refute String.starts_with?(data_dir, Path.expand("../../priv/data", __DIR__))
    refute String.starts_with?(data_dir, BDS.Projects.private_dir())
    assert String.starts_with?(data_dir, Application.fetch_env!(:bds, :default_content_root))
  end

  test "project_data_dir never falls back into the application repo" do
    # A project without an explicit data_path resolves to the per-user default
    # content location, not priv/data/projects/<id> inside the repo.
    project = %Project{id: "no-path-#{System.unique_integer([:positive])}", data_path: nil}

    data_dir = BDS.Projects.project_data_dir(project)

    refute String.starts_with?(data_dir, Path.expand("../../priv/data", __DIR__))
    assert String.starts_with?(data_dir, Application.fetch_env!(:bds, :default_content_root))
  end

  test "project locations are recorded in a machine-local registry under private_dir", %{
    temp_root: temp_root
  } do
    external_dir = Path.join(temp_root, "registry-blog")
    File.mkdir_p!(external_dir)

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Registry Blog", data_path: external_dir})

    registry = BDS.Projects.project_registry()
    assert registry[project.id] == external_dir
    assert String.starts_with?(BDS.Projects.registry_path(), BDS.Projects.private_dir())

    assert {:ok, _deleted} = BDS.Projects.delete_project(project.id)
    refute Map.has_key?(BDS.Projects.project_registry(), project.id)
  end

  test "delete_project rejects the default and active projects", %{temp_root: temp_root} do
    Repo.delete_all(Project)

    assert {:ok, default_project} = BDS.Projects.ensure_default_project()

    assert {:error, :cannot_delete_default_project} =
             BDS.Projects.delete_project(default_project.id)

    temp_dir = Path.join(temp_root, "active-delete")
    File.mkdir_p!(temp_dir)

    assert {:ok, project} = BDS.Projects.create_project(%{name: "Delete Me", data_path: temp_dir})
    assert {:ok, _active_project} = BDS.Projects.set_active_project(project.id)

    assert {:error, :cannot_delete_active_project} = BDS.Projects.delete_project(project.id)
    project_id = project.id
    assert %Project{id: ^project_id} = BDS.Projects.get_project(project.id)
  end

  test "delete_project removes internal project data but preserves external data paths", %{
    temp_root: temp_root
  } do
    assert {:ok, internal_project} = BDS.Projects.create_project(%{name: "Internal Project"})

    internal_dir = BDS.Projects.project_data_dir(internal_project)

    on_exit(fn ->
      _ = File.rm_rf(internal_dir)
    end)

    refute File.exists?(Path.join(internal_dir, "templates/single-post.liquid"))

    assert {:ok, deleted_internal_project} = BDS.Projects.delete_project(internal_project.id)
    assert deleted_internal_project.id == internal_project.id
    assert BDS.Projects.get_project(internal_project.id) == nil
    refute File.exists?(internal_dir)

    external_dir = Path.join(temp_root, "external-delete")
    File.mkdir_p!(external_dir)

    assert {:ok, external_project} =
             BDS.Projects.create_project(%{name: "External Project", data_path: external_dir})

    marker_path = Path.join(external_dir, "keep.txt")
    File.write!(marker_path, "preserve me")

    assert {:ok, deleted_external_project} = BDS.Projects.delete_project(external_project.id)
    assert deleted_external_project.id == external_project.id
    assert BDS.Projects.get_project(external_project.id) == nil
    assert File.read!(marker_path) == "preserve me"
  end

  test "create_project loads project metadata from an existing filesystem-backed blog", %{
    temp_root: temp_root
  } do
    external_dir = Path.join(temp_root, "imported-blog")
    meta_dir = Path.join(external_dir, "meta")
    File.mkdir_p!(meta_dir)

    File.write!(
      Path.join(meta_dir, "project.json"),
      Jason.encode!(%{
        "name" => "Imported Blog",
        "description" => "Filesystem metadata",
        "publicUrl" => "https://imported.example",
        "mainLanguage" => "de",
        "defaultAuthor" => "Importer",
        "maxPostsPerPage" => 17,
        "blogmarkCategory" => "notes",
        "picoTheme" => "slate",
        "semanticSimilarityEnabled" => true,
        "blogLanguages" => ["en", "fr"]
      })
    )

    File.write!(
      Path.join(meta_dir, "publishing.json"),
      Jason.encode!(%{
        "sshHost" => "upload.example",
        "sshUser" => "deploy",
        "sshRemotePath" => "/srv/imported",
        "sshMode" => "rsync"
      })
    )

    assert {:ok, project} =
             BDS.Projects.create_project(%{name: "Placeholder", data_path: external_dir})

    assert BDS.Projects.get_project!(project.id).name == "Imported Blog"

    assert {:ok, metadata} = Metadata.get_project_metadata(project.id)
    assert metadata.name == "Imported Blog"
    assert metadata.description == "Filesystem metadata"
    assert metadata.public_url == "https://imported.example"
    assert metadata.main_language == "de"
    assert metadata.default_author == "Importer"
    assert metadata.max_posts_per_page == 17
    assert metadata.blogmark_category == "notes"
    assert metadata.pico_theme == "slate"
    assert metadata.semantic_similarity_enabled == true
    assert metadata.blog_languages == ["en", "fr"]

    assert metadata.publishing_preferences == %{
             "ssh_host" => "upload.example",
             "ssh_user" => "deploy",
             "ssh_remote_path" => "/srv/imported",
             "ssh_mode" => "rsync"
           }
  end
end
