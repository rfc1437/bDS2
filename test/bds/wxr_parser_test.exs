defmodule BDS.WxrParserTest do
  use ExUnit.Case, async: true

  alias BDS.WxrParser

  test "parse_xml extracts site info, posts, pages, media, categories, and tags" do
    parsed = WxrParser.parse_xml(sample_wxr_xml())

    assert parsed.site.title == "Legacy Blog"
    assert parsed.site.link == "https://legacy.example"
    assert parsed.site.description == "Imported from the legacy desktop app"
    assert parsed.site.language == "en"

    assert parsed.categories == [%{name: "General", slug: "general", parent: ""}]
    assert parsed.tags == [%{name: "News", slug: "news"}]

    assert [
             %{
               wp_id: 101,
               title: "Hello World",
               slug: "hello-world",
               creator: "Importer",
               status: "publish",
               post_type: "post",
               categories: ["General"],
               tags: ["News"]
             }
           ] = parsed.posts

    assert [
             %{
               wp_id: 201,
               title: "About",
               slug: "about",
               post_type: "page",
               categories: ["General"],
               tags: []
             }
           ] = parsed.pages

    assert [media] = parsed.media
    assert media.wp_id == 301
    assert media.title == "Import Asset"
    assert media.filename == "import-asset.txt"
    assert media.relative_path == "2024/05/import-asset.txt"
    assert media.parent_id == 101
    assert media.mime_type == "text/plain"
  end

  test "parse_xml raises when the WXR file has no channel" do
    assert_raise RuntimeError, ~r/no <channel> element found/, fn ->
      WxrParser.parse_xml("<rss version=\"2.0\"></rss>")
    end
  end

  defp sample_wxr_xml do
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
          <content:encoded><![CDATA[<p>Hello <strong>world</strong>.</p><p>[gallery ids="1,2"]</p>]]></content:encoded>
          <excerpt:encoded><![CDATA[Legacy hello]]></excerpt:encoded>
          <wp:post_id>101</wp:post_id>
          <wp:post_date>2024-05-01 14:00:00</wp:post_date>
          <wp:post_modified>2024-05-02 15:00:00</wp:post_modified>
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
end
