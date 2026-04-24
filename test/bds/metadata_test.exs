defmodule BDS.MetadataTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-metadata-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Metadata", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "update_project_metadata writes meta/project.json and load returns the saved values", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               name: "Renamed Blog",
               description: "Description",
               public_url: "https://example.com",
               main_language: "en",
               default_author: "Writer",
               max_posts_per_page: 25,
               blogmark_category: "links",
               pico_theme: "blue",
               semantic_similarity_enabled: true,
               blog_languages: ["de", "fr"]
             })

    assert metadata.name == "Renamed Blog"
    assert metadata.max_posts_per_page == 25
    assert metadata.blog_languages == ["de", "fr"]

    project_json_path = Path.join([temp_dir, "meta", "project.json"])

    assert %{
             "name" => "Renamed Blog",
             "description" => "Description",
             "public_url" => "https://example.com",
             "main_language" => "en",
             "default_author" => "Writer",
             "max_posts_per_page" => 25,
             "blogmark_category" => "links",
             "pico_theme" => "blue",
             "semantic_similarity_enabled" => true,
             "blog_languages" => ["de", "fr"]
           } = Jason.decode!(File.read!(project_json_path))

    assert {:ok, loaded} = BDS.Metadata.get_project_metadata(project.id)
    assert loaded.name == "Renamed Blog"
    assert loaded.public_url == "https://example.com"
    assert loaded.blog_languages == ["de", "fr"]
  end

  test "category and publishing updates write their meta files and sync_project_metadata_from_filesystem loads them",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} = BDS.Metadata.add_category(project.id, "news")

    assert {:ok, _metadata} =
             BDS.Metadata.update_category_settings(project.id, "news", %{
               render_in_lists: false,
               show_title: true,
               post_template_slug: "article",
               list_template_slug: "listing"
             })

    assert {:ok, _metadata} =
             BDS.Metadata.set_publishing_preferences(project.id, %{
               ssh_host: "example.com",
               ssh_user: "deploy",
               ssh_remote_path: "/srv/site",
               ssh_mode: "rsync"
             })

    categories_path = Path.join([temp_dir, "meta", "categories.json"])
    category_meta_path = Path.join([temp_dir, "meta", "category-meta.json"])
    publishing_path = Path.join([temp_dir, "meta", "publishing.json"])

    assert %{"categories" => ["article", "aside", "news", "page", "picture"]} =
             Jason.decode!(File.read!(categories_path))

    assert %{
             "categories" => %{
               "news" => %{
                 "render_in_lists" => false,
                 "show_title" => true,
                 "post_template_slug" => "article",
                 "list_template_slug" => "listing"
               }
             }
           } = Jason.decode!(File.read!(category_meta_path))

    assert %{
             "ssh_host" => "example.com",
             "ssh_user" => "deploy",
             "ssh_remote_path" => "/srv/site",
             "ssh_mode" => "rsync"
           } = Jason.decode!(File.read!(publishing_path))

    assert {:ok, synced} = BDS.Metadata.sync_project_metadata_from_filesystem(project.id)
    assert synced.categories == ["article", "aside", "news", "page", "picture"]

    assert synced.category_settings["news"] == %{
             "render_in_lists" => false,
             "show_title" => true,
             "post_template_slug" => "article",
             "list_template_slug" => "listing"
           }

    assert synced.publishing_preferences == %{
             "ssh_host" => "example.com",
             "ssh_user" => "deploy",
             "ssh_remote_path" => "/srv/site",
             "ssh_mode" => "rsync"
           }
  end

  test "enabling semantic similarity backfills embeddings for existing published posts", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Backfill Me",
               content: "space rocket orbit mission galaxy",
               language: "en"
             })

    assert {:ok, post} = BDS.Posts.publish_post(post.id)
    assert BDS.Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: post.id) == nil

    assert {:ok, metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{semantic_similarity_enabled: true})

    assert metadata.semantic_similarity_enabled == true
    assert BDS.Repo.get_by(BDS.Embeddings.Key, project_id: project.id, post_id: post.id) != nil
    assert File.exists?(BDS.Embeddings.index_path(project.id))
  end
end
