defmodule BDS.SearchTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Search", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "search_posts indexes writes, supports filters and pagination, and removes deleted posts",
       %{project: project} do
    assert {:ok, draft_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Galaxy Draft",
               content: "alpha nebula body",
               tags: ["space", "draft"],
               categories: ["astronomy"],
               language: "en"
             })

    assert {:ok, published_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Galaxy Published",
               content: "alpha nebula published",
               tags: ["space", "published"],
               categories: ["astronomy"],
               language: "de"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(published_post.id)

    assert {:ok, archived_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Galaxy Archived",
               content: "alpha nebula archive",
               tags: ["space", "archived"],
               categories: ["history"],
               language: "en"
             })

    assert {:ok, archived_post} = BDS.Posts.archive_post(archived_post.id)

    assert {:ok, results} = BDS.Search.search_posts(project.id, "nebula", %{status: :draft})
    assert results.total == 1
    assert results.offset == 0
    assert results.limit == 50
    assert Enum.map(results.posts, & &1.id) == [draft_post.id]

    assert {:ok, tag_results} =
             BDS.Search.search_posts(project.id, "galaxy", %{
               tags: ["space"],
               categories: ["astronomy"]
             })

    assert tag_results.total == 2

    assert Enum.sort(Enum.map(tag_results.posts, & &1.id)) ==
             Enum.sort([draft_post.id, published_post.id])

    assert {:ok, language_results} =
             BDS.Search.search_posts(project.id, "galaxy", %{language: "de"})

    assert Enum.map(language_results.posts, & &1.id) == [published_post.id]

    assert {:ok, paged_results} =
             BDS.Search.search_posts(project.id, "galaxy", %{limit: 1, offset: 1})

    assert paged_results.total == 3
    assert paged_results.offset == 1
    assert paged_results.limit == 1
    assert length(paged_results.posts) == 1

    assert {:ok, updated_post} = BDS.Posts.update_post(draft_post.id, %{title: "Comet Draft"})
    assert {:ok, empty_results} = BDS.Search.search_posts(project.id, "Galaxy Draft", %{})
    assert empty_results.total == 0

    assert {:ok, updated_results} = BDS.Search.search_posts(project.id, "Comet Draft", %{})
    assert Enum.map(updated_results.posts, & &1.id) == [updated_post.id]

    assert {:ok, :deleted} = BDS.Posts.delete_post(archived_post.id)
    assert {:ok, deleted_results} = BDS.Search.search_posts(project.id, "Galaxy Archived", %{})
    assert deleted_results.total == 0
  end

  test "search_posts includes translation text after reindexing", %{project: project} do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Canonical",
               content: "root body",
               language: "en"
             })

    now = System.system_time(:second)

    Repo.query!(
      """
      INSERT INTO post_translations (
        id, project_id, translation_for, language, title, excerpt, content, status,
        created_at, updated_at, published_at, file_path, checksum
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Ecto.UUID.generate(),
        project.id,
        post.id,
        "fr",
        "Bonjour galaxie",
        "Resume",
        "contenu lunaire",
        "draft",
        now,
        now,
        nil,
        "",
        nil
      ]
    )

    assert :ok = BDS.Search.reindex_project(project.id)

    assert {:ok, results} = BDS.Search.search_posts(project.id, "lunaire", %{})
    assert Enum.map(results.posts, & &1.id) == [post.id]

    assert {:ok, missing_translation_results} =
             BDS.Search.search_posts(project.id, "Canonical", %{
               missing_translation_language: "de"
             })

    assert Enum.map(missing_translation_results.posts, & &1.id) == [post.id]
  end

  test "search_media indexes metadata, includes translation text, and removes deleted media", %{
    project: project,
    temp_dir: temp_dir
  } do
    source_path = Path.join(temp_dir, "hero.txt")
    File.write!(source_path, "hero")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Aurora asset",
               alt: "Orbit illustration",
               caption: "Captioned item",
               tags: ["space"]
             })

    assert {:ok, _translation} =
             BDS.Media.upsert_media_translation(media.id, "de", %{
               title: "Weltraum Titel",
               alt: "Orbit auf Deutsch",
               caption: "Beschriftung"
             })

    assert {:ok, results} = BDS.Search.search_media(project.id, "Orbit", %{})
    assert Enum.map(results.media, & &1.id) == [media.id]

    assert {:ok, translated_results} = BDS.Search.search_media(project.id, "Weltraum", %{})
    assert Enum.map(translated_results.media, & &1.id) == [media.id]

    assert {:ok, updated_media} = BDS.Media.update_media(media.id, %{title: "Renamed asset"})
    assert {:ok, old_results} = BDS.Search.search_media(project.id, "Aurora", %{})
    assert old_results.total == 0

    assert {:ok, new_results} = BDS.Search.search_media(project.id, "Renamed", %{})
    assert Enum.map(new_results.media, & &1.id) == [updated_media.id]

    assert {:ok, :deleted} = BDS.Media.delete_media(media.id)
    assert {:ok, deleted_results} = BDS.Search.search_media(project.id, "Renamed", %{})
    assert deleted_results.total == 0
  end

  test "rebuild operations repopulate the search index from filesystem truth", %{
    project: project,
    temp_dir: temp_dir
  } do
    posts_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(posts_dir)

    File.write!(
      Path.join(posts_dir, "filesystem-post.md"),
      [
        "---",
        "id: search-post-from-file",
        "title: File Search Post",
        "slug: filesystem-post",
        "status: published",
        "language: en",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "published_at: 1712016000",
        "tags:",
        "  - filesystem",
        "categories:",
        "  - imports",
        "---",
        "starlight filesystem body",
        ""
      ]
      |> Enum.join("\n")
    )

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "filesystem.txt"), "media body")

    File.write!(
      Path.join(media_dir, "filesystem.txt.meta"),
      [
        "id: search-media-from-file",
        "original_name: filesystem.txt",
        "mime_type: text/plain",
        "size: 10",
        "title: File Search Media",
        "alt: imported alt",
        "caption: imported caption",
        "language: en",
        "created_at: 1711843200",
        "updated_at: 1711929600",
        "tags:",
        "  - filesystem",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, _posts} = BDS.Posts.rebuild_posts_from_files(project.id)
    assert {:ok, _media} = BDS.Media.rebuild_media_from_files(project.id)

    assert {:ok, post_results} = BDS.Search.search_posts(project.id, "starlight", %{})
    assert Enum.map(post_results.posts, & &1.id) == ["search-post-from-file"]

    assert {:ok, media_results} = BDS.Search.search_media(project.id, "imported", %{})
    assert Enum.map(media_results.media, & &1.id) == ["search-media-from-file"]
  end

  test "search_posts applies language-aware stemming to indexed and query text", %{
    project: project
  } do
    assert {:ok, german_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Morgenroutine",
               content: "Die Katzen schlafen am Fenster.",
               language: "de"
             })

    assert {:ok, french_post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Routine matinale",
               content: "Je cours chaque matin avant le travail.",
               language: "fr"
             })

    assert {:ok, german_results} = BDS.Search.search_posts(project.id, "katze", %{})
    assert Enum.map(german_results.posts, & &1.id) == [german_post.id]

    assert {:ok, french_results} = BDS.Search.search_posts(project.id, "courir", %{})
    assert Enum.map(french_results.posts, & &1.id) == [french_post.id]
  end

  test "lists supported stemmer languages using normalized ISO codes" do
    languages = BDS.Search.list_stemmer_languages()

    assert is_list(languages)
    assert length(languages) == 24
    assert "en" in languages
    assert "de" in languages
    assert "fr" in languages
    assert "it" in languages
    assert "es" in languages
    assert "ar" in languages
    assert "ca" in languages
    assert "el" in languages
    assert "ga" in languages
    assert "hi" in languages
    assert Enum.uniq(languages) == languages
  end
end
