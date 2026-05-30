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
             "publicUrl" => "https://example.com",
             "mainLanguage" => "en",
             "defaultAuthor" => "Writer",
             "maxPostsPerPage" => 25,
             "blogmarkCategory" => "links",
             "picoTheme" => "blue",
             "semanticSimilarityEnabled" => true,
             "blogLanguages" => ["de", "fr"]
           } = Jason.decode!(File.read!(project_json_path))

    assert {:ok, loaded} = BDS.Metadata.get_project_metadata(project.id)
    assert loaded.name == "Renamed Blog"
    assert loaded.public_url == "https://example.com"
    assert loaded.blog_languages == ["de", "fr"]
  end

  test "update_project_metadata keeps committed database changes when filesystem flush fails", %{
    project: project,
    temp_dir: temp_dir
  } do
    meta_path = Path.join(temp_dir, "meta")
    File.rm_rf!(meta_path)
    File.write!(meta_path, "not a directory")

    assert {:error, _reason} =
             BDS.Metadata.update_project_metadata(project.id, %{
               name: "Committed Metadata",
               description: "Stored before flush"
             })

    assert BDS.Projects.get_project!(project.id).name == "Committed Metadata"

    assert {:ok, loaded} = BDS.Metadata.get_project_metadata(project.id)
    assert loaded.name == "Committed Metadata"
    assert loaded.description == "Stored before flush"
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

    assert ["article", "aside", "news", "page", "picture"] =
             Jason.decode!(File.read!(categories_path))

    assert %{
             "news" => %{
               "renderInLists" => false,
               "showTitle" => true,
               "postTemplateSlug" => "article",
               "listTemplateSlug" => "listing"
             }
           } = Jason.decode!(File.read!(category_meta_path))

    assert %{
             "sshHost" => "example.com",
             "sshUser" => "deploy",
             "sshRemotePath" => "/srv/site",
             "sshMode" => "rsync"
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

  test "sync_project_metadata_from_filesystem reads canonical bDS metadata file shapes", %{
    project: project,
    temp_dir: temp_dir
  } do
    meta_dir = Path.join(temp_dir, "meta")
    File.mkdir_p!(meta_dir)

    File.write!(
      Path.join(meta_dir, "project.json"),
      Jason.encode!(%{
        "name" => "Legacy Blog",
        "description" => "Imported",
        "publicUrl" => "https://legacy.example",
        "mainLanguage" => "de",
        "defaultAuthor" => "Legacy Writer",
        "maxPostsPerPage" => 17,
        "blogmarkCategory" => "aside",
        "picoTheme" => "slate",
        "semanticSimilarityEnabled" => true,
        "blogLanguages" => ["en"]
      })
    )

    File.write!(
      Path.join(meta_dir, "categories.json"),
      Jason.encode!(["article", "aside", "legacy", "page", "picture"])
    )

    File.write!(
      Path.join(meta_dir, "category-meta.json"),
      Jason.encode!(%{
        "legacy" => %{
          "renderInLists" => false,
          "showTitle" => true,
          "postTemplateSlug" => "feature-view",
          "listTemplateSlug" => "feature-list",
          "title" => "Legacy"
        }
      })
    )

    File.write!(
      Path.join(meta_dir, "publishing.json"),
      Jason.encode!(%{
        "sshHost" => "legacy.example",
        "sshUser" => "deploy",
        "sshRemotePath" => "/srv/legacy",
        "sshMode" => "rsync"
      })
    )

    assert {:ok, synced} = BDS.Metadata.sync_project_metadata_from_filesystem(project.id)

    assert synced.name == "Legacy Blog"
    assert synced.description == "Imported"
    assert synced.public_url == "https://legacy.example"
    assert synced.main_language == "de"
    assert synced.default_author == "Legacy Writer"
    assert synced.max_posts_per_page == 17
    assert synced.blogmark_category == "aside"
    assert synced.pico_theme == "slate"
    assert synced.semantic_similarity_enabled == true
    assert synced.blog_languages == ["en"]
    assert synced.categories == ["article", "aside", "legacy", "page", "picture"]

    assert synced.category_settings["legacy"] == %{
             "render_in_lists" => false,
             "show_title" => true,
             "post_template_slug" => "feature-view",
             "list_template_slug" => "feature-list",
             "title" => "Legacy"
           }

    assert synced.publishing_preferences == %{
             "ssh_host" => "legacy.example",
             "ssh_user" => "deploy",
             "ssh_remote_path" => "/srv/legacy",
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

    # Index persistence is debounced (5s); force it to assert the file.
    :ok = BDS.Embeddings.Index.flush(project.id)
    assert File.exists?(BDS.Embeddings.index_path(project.id))
  end

  test "remove_category removes the category and its settings from state, files, and DB", %{
    project: project,
    temp_dir: temp_dir
  } do
    # Add a category + settings first
    assert {:ok, metadata} = BDS.Metadata.add_category(project.id, "news")
    assert "news" in metadata.categories

    assert {:ok, _metadata} =
             BDS.Metadata.update_category_settings(project.id, "news", %{
               render_in_lists: false,
               show_title: true,
               post_template_slug: "article"
             })

    # Remove the category
    assert {:ok, updated} = BDS.Metadata.remove_category(project.id, "news")

    # 1. Category removed from in-memory list
    refute "news" in updated.categories
    assert "article" in updated.categories
    assert "aside" in updated.categories
    assert "page" in updated.categories
    assert "picture" in updated.categories

    # 2. Category settings removed from in-memory map
    refute Map.has_key?(updated.category_settings, "news")

    # 3. Verify via get_project_metadata
    assert {:ok, loaded} = BDS.Metadata.get_project_metadata(project.id)
    refute "news" in loaded.categories
    refute Map.has_key?(loaded.category_settings, "news")

    # 4. meta/categories.json rewritten without the removed category
    categories_path = Path.join([temp_dir, "meta", "categories.json"])
    assert ["article", "aside", "page", "picture"] =
             Jason.decode!(File.read!(categories_path))

    # 5. meta/category-meta.json rewritten without the removed category's settings
    category_meta_path = Path.join([temp_dir, "meta", "category-meta.json"])
    category_meta = Jason.decode!(File.read!(category_meta_path))
    refute Map.has_key?(category_meta, "news")

    # 6. DB settings updated
    cat_setting =
      BDS.Repo.get(BDS.Settings.Setting, "project:#{project.id}:categories")
    assert cat_setting != nil
    refute "news" in (cat_setting.value |> Jason.decode!() |> Map.get("categories", []))

    meta_setting =
      BDS.Repo.get(BDS.Settings.Setting, "project:#{project.id}:category_meta")
    assert meta_setting != nil
    meta_categories = meta_setting.value |> Jason.decode!() |> Map.get("categories", %{})
    refute Map.has_key?(meta_categories, "news")
  end

  test "remove_category is a no-op for non-existent category", %{
    project: project
  } do
    {:ok, metadata_before} = BDS.Metadata.get_project_metadata(project.id)

    assert {:ok, metadata} = BDS.Metadata.remove_category(project.id, "nonexistent")
    assert metadata.categories == metadata_before.categories
  end

  test "sync_project_metadata_from_filesystem materializes the canonical metadata files when missing",
       %{project: project, temp_dir: temp_dir} do
    meta_dir = Path.join(temp_dir, "meta")

    File.rm_rf!(meta_dir)

    refute File.exists?(Path.join(meta_dir, "project.json"))
    refute File.exists?(Path.join(meta_dir, "categories.json"))
    refute File.exists?(Path.join(meta_dir, "category-meta.json"))
    refute File.exists?(Path.join(meta_dir, "publishing.json"))

    assert {:ok, metadata} = BDS.Metadata.sync_project_metadata_from_filesystem(project.id)

    assert metadata.name == project.name
    assert File.exists?(Path.join(meta_dir, "project.json"))
    assert File.exists?(Path.join(meta_dir, "categories.json"))
    assert File.exists?(Path.join(meta_dir, "category-meta.json"))
    assert File.exists?(Path.join(meta_dir, "publishing.json"))

    refute File.exists?(Path.join(meta_dir, "project.json.tmp"))
    refute File.exists?(Path.join(meta_dir, "categories.json.tmp"))
    refute File.exists?(Path.join(meta_dir, "category-meta.json.tmp"))
    refute File.exists?(Path.join(meta_dir, "publishing.json.tmp"))
  end
end
