defmodule BDS.Generation.ValidationTest do
  use ExUnit.Case, async: true

  alias BDS.Generation.Validation

  @base_url "https://example.com/blog"
  @post_url_path "/2026/06/01/sample-post"

  setup do
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-validation-#{System.unique_integer([:positive])}")

    html_dir = Path.join(temp_dir, "html")
    post_html_path = Path.join([html_dir, "2026", "06", "01", "sample-post", "index.html"])
    source_path = Path.join(temp_dir, "sample-post.md")

    File.mkdir_p!(Path.dirname(post_html_path))
    File.write!(Path.join(html_dir, "index.html"), "<html>home</html>")
    File.write!(post_html_path, "<html>post</html>")
    File.write!(source_path, "Sample body")
    on_exit(fn -> File.rm_rf(temp_dir) end)

    %{html_dir: html_dir, post_html_path: post_html_path, source_path: source_path}
  end

  defp compare(html_dir, source_path, generated_updated_at_ms) do
    sitemap_xml =
      Enum.join([
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
        ~s(<url><loc>#{@base_url}/</loc></url>),
        ~s(<url><loc>#{@base_url}#{@post_url_path}/</loc></url>),
        ~s(</urlset>)
      ])

    Validation.compare_sitemap_to_html(%{
      sitemap_xml: sitemap_xml,
      base_url: @base_url,
      html_dir: html_dir,
      on_progress: nil,
      post_timestamp_checks: [
        %{
          post_url_path: @post_url_path,
          post_file_path: source_path,
          generated_updated_at_ms: generated_updated_at_ms
        }
      ]
    })
  end

  test "does not report a post as updated when its source mtime second adjoins the generation timestamp",
       %{html_dir: html_dir, post_html_path: post_html_path, source_path: source_path} do
    source_mtime = System.os_time(:second)

    File.touch!(source_path, source_mtime)
    File.touch!(post_html_path, source_mtime - 5)
    File.touch!(Path.join(html_dir, "index.html"), source_mtime - 5)

    generated_updated_at_ms = source_mtime * 1000 - 100

    result = compare(html_dir, source_path, generated_updated_at_ms)

    assert result.missing_url_paths == []
    assert result.extra_url_paths == []
    assert result.updated_post_url_paths == []
  end

  test "does not report a post as updated when its source mtime is in the same second as the generation timestamp",
       %{html_dir: html_dir, post_html_path: post_html_path, source_path: source_path} do
    source_mtime = System.os_time(:second)

    File.touch!(source_path, source_mtime)
    File.touch!(post_html_path, source_mtime - 5)
    File.touch!(Path.join(html_dir, "index.html"), source_mtime - 5)

    generated_updated_at_ms = source_mtime * 1000 + 500

    result = compare(html_dir, source_path, generated_updated_at_ms)

    assert result.updated_post_url_paths == []
  end

  test "reports a post as updated when its source mtime is beyond the granularity tolerance",
       %{html_dir: html_dir, post_html_path: post_html_path, source_path: source_path} do
    source_mtime = System.os_time(:second)

    File.touch!(source_path, source_mtime)
    File.touch!(post_html_path, source_mtime - 5)
    File.touch!(Path.join(html_dir, "index.html"), source_mtime - 5)

    generated_updated_at_ms = (source_mtime - 5) * 1000

    result = compare(html_dir, source_path, generated_updated_at_ms)

    assert result.updated_post_url_paths == [@post_url_path]
  end
end
