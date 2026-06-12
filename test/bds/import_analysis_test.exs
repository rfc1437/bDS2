defmodule BDS.ImportAnalysisTest do
  use ExUnit.Case, async: false

  alias BDS.ImportAnalysis
  alias BDS.Media
  alias BDS.Posts
  alias BDS.Tags

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-import-analysis-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Import Analysis", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "analyze_wxr summarizes new items, date distribution, and macros", %{
    project: project,
    temp_dir: temp_dir
  } do
    uploads_dir = Path.join(temp_dir, "uploads")
    File.mkdir_p!(Path.join(uploads_dir, "2024/05"))
    File.write!(Path.join(uploads_dir, "2024/05/import-asset.txt"), "legacy attachment")

    wxr_path = Path.join(temp_dir, "legacy.xml")
    File.write!(wxr_path, basic_wxr_xml())

    assert {:ok, report} = ImportAnalysis.analyze_wxr(project.id, wxr_path, uploads_dir)

    assert report.site_info.title == "Legacy Blog"
    assert report.site_info.url == "https://legacy.example"
    assert report.site_info.language == "en"
    assert report.site_info.source_file == wxr_path

    assert report.post_stats == %{
             new_count: 1,
             update_count: 0,
             conflict_count: 0,
             duplicate_count: 0
           }

    assert report.page_stats == %{
             new_count: 1,
             update_count: 0,
             conflict_count: 0,
             duplicate_count: 0
           }

    assert report.media_stats == %{
             new_count: 1,
             update_count: 0,
             conflict_count: 0,
             duplicate_count: 0,
             missing_count: 0
           }

    assert report.category_stats == %{existing_count: 0, mapped_count: 0, new_count: 1}
    assert report.tag_stats == %{existing_count: 0, mapped_count: 0, new_count: 1}

    assert Enum.any?(report.date_distribution, fn row ->
             row.year == 2024 and row.post_count == 2 and row.media_count == 1
           end)

    assert %{
             total: 1,
             mapped_count: 0,
             unmapped_count: 1,
             discovered: [
               %{
                 name: "gallery",
                 mapped: false,
                 total_count: 1,
                 usages: [%{params: %{"ids" => "1,2"}, count: 1, validation_status: "unknown"}],
                 post_slugs: ["hello-world"]
               }
             ]
           } = report.macros

    assert report.conflicts == []

    assert [
             %{
               title: "Hello World",
               slug: "hello-world",
               status: "new",
               item_type: "post",
               post_type: "post"
             }
           ] =
             report.items.posts

    assert [%{title: "About", slug: "about", status: "new", item_type: "page"} = page_item] =
             report.items.pages

    assert Map.get(page_item, :post_type) == "page"

    assert [
             %{
               title: "Import Asset",
               filename: "import-asset.txt",
               relative_path: "2024/05/import-asset.txt",
               status: "new",
               item_type: "media"
             }
           ] =
             report.items.media
  end

  test "analyze_wxr detects update, conflict, duplicate, existing taxonomy, and missing uploads",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _category} = Tags.create_tag(%{project_id: project.id, name: "General"})
    assert {:ok, _tag} = Tags.create_tag(%{project_id: project.id, name: "News"})

    assert {:ok, _update_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Update Me",
               content: "Update body",
               checksum: sha256("Update body")
             })

    assert {:ok, _conflict_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Conflict Me",
               content: "Local body",
               checksum: sha256("Local body")
             })

    assert {:ok, _duplicate_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Existing Duplicate",
               content: "Duplicate body",
               checksum: sha256("Duplicate body")
             })

    existing_media_source = Path.join(temp_dir, "update-asset.txt")
    File.write!(existing_media_source, "shared bytes")

    assert {:ok, _existing_media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: existing_media_source,
               title: "Update Asset"
             })

    wxr_path = Path.join(temp_dir, "conflicts.xml")
    File.write!(wxr_path, conflict_wxr_xml())

    assert {:ok, report} = ImportAnalysis.analyze_wxr(project.id, wxr_path, nil)

    assert report.post_stats == %{
             new_count: 0,
             update_count: 1,
             conflict_count: 1,
             duplicate_count: 1
           }

    assert report.page_stats == %{
             new_count: 0,
             update_count: 0,
             conflict_count: 0,
             duplicate_count: 0
           }

    assert report.media_stats == %{
             new_count: 0,
             update_count: 0,
             conflict_count: 0,
             duplicate_count: 0,
             missing_count: 1
           }

    assert report.category_stats == %{existing_count: 1, mapped_count: 0, new_count: 0}
    assert report.tag_stats == %{existing_count: 1, mapped_count: 0, new_count: 0}

    assert Enum.any?(report.conflicts, fn conflict ->
             conflict.item_type == "post" and conflict.item_name == "conflict-me" and
               conflict.resolution == "ignore"
           end)

    assert Enum.any?(report.items.posts, &(&1.slug == "update-me" and &1.status == "update"))
    assert Enum.any?(report.items.posts, &(&1.slug == "conflict-me" and &1.status == "conflict"))

    assert Enum.any?(
             report.items.posts,
             &(&1.slug == "duplicate-me" and &1.status == "content-duplicate")
           )

    assert Enum.any?(
             report.items.media,
             &(&1.filename == "missing-asset.txt" and &1.status == "missing")
           )
  end

  test "analyze_wxr reports legacy progress steps while building the import report", %{
    project: project,
    temp_dir: temp_dir
  } do
    uploads_dir = Path.join(temp_dir, "uploads")
    File.mkdir_p!(Path.join(uploads_dir, "2024/05"))
    File.write!(Path.join(uploads_dir, "2024/05/import-asset.txt"), "legacy attachment")

    wxr_path = Path.join(temp_dir, "legacy.xml")
    File.write!(wxr_path, basic_wxr_xml())

    assert {:ok, _report} =
             ImportAnalysis.analyze_wxr(project.id, wxr_path, uploads_dir,
               on_progress: fn step, detail ->
                 send(self(), {:analysis_progress, step, detail})
               end
             )

    assert_received {:analysis_progress, "Loading existing posts...", nil}
    assert_received {:analysis_progress, "Analyzing posts...", "1 posts to analyze"}
    assert_received {:analysis_progress, "Analyzing pages...", "1 pages to analyze"}
    assert_received {:analysis_progress, "Analyzing media files...", "1 media files to analyze"}
    assert_received {:analysis_progress, "Discovering macros...", nil}
  end

  import ExUnit.CaptureLog

  test "analyze_wxr logs and continues when the progress callback raises", %{
    project: project,
    temp_dir: temp_dir
  } do
    uploads_dir = Path.join(temp_dir, "uploads")
    File.mkdir_p!(Path.join(uploads_dir, "2024/05"))
    File.write!(Path.join(uploads_dir, "2024/05/import-asset.txt"), "legacy attachment")

    wxr_path = Path.join(temp_dir, "legacy.xml")
    File.write!(wxr_path, basic_wxr_xml())

    log =
      capture_log(fn ->
        assert {:ok, _report} =
                 ImportAnalysis.analyze_wxr(project.id, wxr_path, uploads_dir,
                   on_progress: fn _step, _detail -> raise "boom" end
                 )
      end)

    assert log =~ "import analysis progress callback failed"
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
          <content:encoded><![CDATA[<p>Hello world</p><p>[gallery ids="1,2"]</p>]]></content:encoded>
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

  defp conflict_wxr_xml do
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
          <title>Update Me</title>
          <link>https://legacy.example/update-me</link>
          <pubDate>Wed, 01 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[<p>Update body</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[]]></excerpt:encoded>
          <wp:post_id>401</wp:post_id>
          <wp:post_date>2024-05-01 12:00:00</wp:post_date>
          <wp:post_modified>2024-05-01 12:30:00</wp:post_modified>
          <wp:post_name>update-me</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>post</wp:post_type>
          <category domain="category" nicename="general"><![CDATA[General]]></category>
          <category domain="post_tag" nicename="news"><![CDATA[News]]></category>
        </item>
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
          <category domain="category" nicename="general"><![CDATA[General]]></category>
          <category domain="post_tag" nicename="news"><![CDATA[News]]></category>
        </item>
        <item>
          <title>Duplicate Me</title>
          <link>https://legacy.example/duplicate-me</link>
          <pubDate>Fri, 03 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[<p>Duplicate body</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[]]></excerpt:encoded>
          <wp:post_id>403</wp:post_id>
          <wp:post_date>2024-05-03 12:00:00</wp:post_date>
          <wp:post_modified>2024-05-03 12:30:00</wp:post_modified>
          <wp:post_name>duplicate-me</wp:post_name>
          <wp:status>publish</wp:status>
          <wp:post_type>post</wp:post_type>
          <category domain="category" nicename="general"><![CDATA[General]]></category>
          <category domain="post_tag" nicename="news"><![CDATA[News]]></category>
        </item>
        <item>
          <title>Missing Asset</title>
          <link>https://legacy.example/wp-content/uploads/2024/05/missing-asset.txt</link>
          <pubDate>Sat, 04 May 2024 12:00:00 +0000</pubDate>
          <dc:creator><![CDATA[Importer]]></dc:creator>
          <content:encoded><![CDATA[Missing attachment]]></content:encoded>
          <wp:post_id>404</wp:post_id>
          <wp:post_parent>401</wp:post_parent>
          <wp:post_name>missing-asset</wp:post_name>
          <wp:status>inherit</wp:status>
          <wp:post_type>attachment</wp:post_type>
          <wp:attachment_url><![CDATA[https://legacy.example/wp-content/uploads/2024/05/missing-asset.txt]]></wp:attachment_url>
        </item>
      </channel>
    </rss>
    """
  end
end
