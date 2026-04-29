defmodule BDS.ImportExecutionTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.ImportAnalysis
  alias BDS.ImportExecution
  alias BDS.Posts
  alias BDS.Repo
  alias BDS.Tags

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-import-execution-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Import Execution", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "execute_import creates tags, posts, pages, and media from the analysis report", %{project: project, temp_dir: temp_dir} do
    uploads_dir = Path.join(temp_dir, "uploads")
    File.mkdir_p!(Path.join(uploads_dir, "2024/05"))
    File.write!(Path.join(uploads_dir, "2024/05/import-asset.txt"), "legacy attachment")

    wxr_path = Path.join(temp_dir, "legacy.xml")
    File.write!(wxr_path, basic_wxr_xml())

    assert {:ok, report} = ImportAnalysis.analyze_wxr(project.id, wxr_path, uploads_dir)

    assert {:ok, result} =
             ImportExecution.execute_import(project.id, report,
               uploads_folder_path: uploads_dir,
               default_author: "Imported Author"
             )

    assert result.success
    assert result.tags == %{created: 2, skipped: 0}
    assert result.posts == %{imported: 1, skipped: 0, errors: 0}
    assert result.pages == %{imported: 1, skipped: 0, errors: 0}
    assert result.media == %{imported: 1, skipped: 0, errors: 0}
    assert result.errors == []

    tag_names = project.id |> Tags.list_tags() |> Enum.map(& &1.name) |> Enum.sort()
    assert tag_names == ["General", "News"]

    posts = Repo.all(from post in Posts.Post, where: post.project_id == ^project.id, order_by: [asc: post.slug])
    assert Enum.map(posts, & &1.slug) == ["about", "hello-world"]

    hello_world = Enum.find(posts, &(&1.slug == "hello-world"))
    about = Enum.find(posts, &(&1.slug == "about"))

    assert hello_world.status == :published
    assert hello_world.author == "Importer"
    assert hello_world.content == nil
    assert hello_world.file_path != ""
    assert File.exists?(Path.join(temp_dir, hello_world.file_path))
    assert File.read!(Path.join(temp_dir, hello_world.file_path)) =~ "Hello World"

    assert about.status == :published
    assert about.content == nil
    assert "page" in about.categories

    imported_media = Repo.one!(from media in BDS.Media.Media, where: media.project_id == ^project.id)
    assert imported_media.original_name == "import-asset.txt"
    assert File.exists?(Path.join(temp_dir, imported_media.file_path))
  end

  test "execute_import skips conflicts by default and can import them with a new slug", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _existing_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Conflict Me",
               content: "Local body",
               checksum: sha256("Local body")
             })

    wxr_path = Path.join(temp_dir, "conflict.xml")
    File.write!(wxr_path, conflict_only_wxr_xml())

    assert {:ok, report} = ImportAnalysis.analyze_wxr(project.id, wxr_path, nil)

    assert {:ok, skipped_result} = ImportExecution.execute_import(project.id, report, default_author: "Imported Author")
    assert skipped_result.posts == %{imported: 0, skipped: 1, errors: 0}
    assert Repo.aggregate(Posts.Post, :count, :id) == 1

    import_report = put_in(report.items.posts, [%{List.first(report.items.posts) | resolution: "import"}])

    assert {:ok, imported_result} = ImportExecution.execute_import(project.id, import_report, default_author: "Imported Author")
    assert imported_result.posts == %{imported: 1, skipped: 0, errors: 0}

    slugs = Repo.all(from post in Posts.Post, where: post.project_id == ^project.id, select: post.slug, order_by: [asc: post.slug])
    assert length(slugs) == 2
    assert "conflict-me" in slugs
    assert Enum.any?(slugs, &(&1 != "conflict-me"))
  end

  test "execute_import reports phase progress while importing", %{project: project, temp_dir: temp_dir} do
    uploads_dir = Path.join(temp_dir, "uploads")
    File.mkdir_p!(Path.join(uploads_dir, "2024/05"))
    File.write!(Path.join(uploads_dir, "2024/05/import-asset.txt"), "legacy attachment")

    wxr_path = Path.join(temp_dir, "legacy.xml")
    File.write!(wxr_path, basic_wxr_xml())

    assert {:ok, report} = ImportAnalysis.analyze_wxr(project.id, wxr_path, uploads_dir)

    assert {:ok, _result} =
             ImportExecution.execute_import(project.id, report,
               uploads_folder_path: uploads_dir,
               default_author: "Imported Author",
               on_progress: fn phase, current, total, detail ->
                 send(self(), {:execution_progress, phase, current, total, detail})
               end
             )

    assert_received {:execution_progress, "tags", 0, 2, "Creating tags..."}
    assert_received {:execution_progress, "posts", 0, 1, "Importing posts..."}
    assert_received {:execution_progress, "media", 0, 1, "Importing media..."}
    assert_received {:execution_progress, "pages", 0, 1, "Importing pages..."}
    assert_received {:execution_progress, "complete", 1, 1, "Import complete"}
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp basic_wxr_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
      xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:wp="http://wordpress.org/export/1.2/">
      <channel>
        <title>Legacy Blog</title>
        <link>https://legacy.example</link>
        <description>Imported from the legacy desktop app</description>
        <language>en</language>
        <wp:category>
          <wp:cat_name><![CDATA[General]]></wp:cat_name>
          <wp:category_nicename>general</wp:category_nicename>
          <wp:category_parent></wp:category_parent>
        </wp:category>
        <wp:tag>
          <wp:tag_slug>news</wp:tag_slug>
          <wp:tag_name><![CDATA[News]]></wp:tag_name>
        </wp:tag>
        <item>
          <title>Hello World</title>
          <link>https://legacy.example/2024/05/hello-world</link>
          <pubDate>Wed, 01 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[<p>Hello world</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[Legacy hello]]></excerpt:encoded>
          <wp:post_id>101</wp:post_id>
          <wp:post_date>2024-05-01 12:00:00</wp:post_date>
          <wp:post_modified>2024-05-01 12:30:00</wp:post_modified>
          <wp:post_name>hello-world</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>post</wp:post_type>
          <category domain="category" nicename="general"><![CDATA[General]]></category>
          <category domain="post_tag" nicename="news"><![CDATA[News]]></category>
        </item>
        <item>
          <title>About</title>
          <link>https://legacy.example/about</link>
          <pubDate>Thu, 02 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[<p>About page</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[]]></excerpt:encoded>
          <wp:post_id>201</wp:post_id>
          <wp:post_date>2024-05-02 12:00:00</wp:post_date>
          <wp:post_modified>2024-05-02 12:30:00</wp:post_modified>
          <wp:post_name>about</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>page</wp:post_type>
          <category domain="category" nicename="general"><![CDATA[General]]></category>
        </item>
        <item>
          <title>Import Asset</title>
          <link>https://legacy.example/wp-content/uploads/2024/05/import-asset.txt</link>
          <pubDate>Fri, 03 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[Legacy text attachment]]></content:encoded>
          <wp:post_id>301</wp:post_id>
          <wp:post_parent>101</wp:post_parent>
          <wp:post_name>import-asset</wp:post_name>
          <wp:status>inherit</wp:status>
          <wp:post_type>attachment</wp:post_type>
          <wp:attachment_url><![CDATA[https://legacy.example/wp-content/uploads/2024/05/import-asset.txt]]></wp:attachment_url>
        </item>
      </channel>
    </rss>
    """
  end

  defp conflict_only_wxr_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
      xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:wp="http://wordpress.org/export/1.2/">
      <channel>
        <title>Legacy Blog</title>
        <link>https://legacy.example</link>
        <description>Imported from the legacy desktop app</description>
        <language>en</language>
        <item>
          <title>Conflict Me</title>
          <link>https://legacy.example/conflict-me</link>
          <pubDate>Thu, 02 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[<p>Incoming conflict body</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[]]></excerpt:encoded>
          <wp:post_id>402</wp:post_id>
          <wp:post_date>2024-05-02 12:00:00</wp:post_date>
          <wp:post_modified>2024-05-02 12:30:00</wp:post_modified>
          <wp:post_name>conflict-me</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>post</wp:post_type>
        </item>
      </channel>
    </rss>
    """
  end
end
