defmodule BDS.PreviewTest do
  use ExUnit.Case, async: false

  alias BDS.Generation
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Preview", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "start_preview binds localhost and request resolves generated routes, assets, media, and draft previews",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, _} =
             Generation.write_generated_file(project.id, "index.html", "<html>home</html>")

    assert {:ok, _} =
             Generation.write_generated_file(
               project.id,
               "de/index.html",
               "<html>startseite</html>"
             )

    assert {:ok, _} =
             Generation.write_generated_file(
               project.id,
               "tag/elixir/index.html",
               "<html>tag archive</html>"
             )

    assert {:ok, _} =
             Generation.write_generated_file(
               project.id,
               "pagefind/pagefind-ui.js",
               "console.log('pagefind')"
             )

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "image.txt"), "media body")

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft Post",
               content: "Draft preview body",
               language: "en"
             })

    assert {:ok, server} = BDS.Preview.start_preview(project.id)
    assert server.host == "127.0.0.1"
    assert server.port == 4123
    assert server.is_running == true

    assert {:ok, %{body: home_html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/")

    assert home_html =~ "<html"

    assert {:ok, %{body: de_html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/de/")

    assert de_html =~ "<html"

    assert {:ok, %{body: tag_html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/tag/elixir")

    assert tag_html =~ "<html"

    assert {:ok, %{body: "console.log('pagefind')", content_type: "application/javascript"}} =
             BDS.Preview.request(project.id, "/pagefind/pagefind-ui.js")

    assert {:ok, %{body: pico_css, content_type: "text/css"}} =
             BDS.Preview.request(project.id, "/assets/pico.min.css")

    assert pico_css =~ ":root"

    assert {:ok, %{body: bds_css, content_type: "text/css"}} =
             BDS.Preview.request(project.id, "/assets/bds.css")

    assert bds_css =~ ".blog-menu"

    assert {:ok, %{body: calendar_runtime, content_type: "application/javascript"}} =
             BDS.Preview.request(project.id, "/assets/calendar-runtime.js")

    assert calendar_runtime =~ "loadCalendarData"
    assert calendar_runtime =~ "window.location.assign"

    assert {:ok, %{body: tag_cloud_runtime, content_type: "application/javascript"}} =
             BDS.Preview.request(project.id, "/assets/tag-cloud.js")

    assert tag_cloud_runtime =~ "data-tag-cloud-words"

    assert {:ok, %{body: _prev_png, content_type: "image/png"}} =
             BDS.Preview.request(project.id, "/images/prev.png")

    assert {:ok, %{body: _loading_gif, content_type: "image/gif"}} =
             BDS.Preview.request(project.id, "/images/loading.gif")

    assert {:ok, %{body: "media body", content_type: "text/plain"}} =
             BDS.Preview.request(project.id, "/media/2026/04/image.txt")

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/draft-post", post.id)

    assert draft_html =~ "Draft preview body"
    assert draft_html =~ ~s(href="/assets/pico.min.css")
    assert {:error, :not_found} = BDS.Preview.request(project.id, "/media/../../secret.txt")

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "draft preview renders through the published post template", %{project: project} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Preview Post",
               kind: :post,
               content:
                 "<article class=\"preview-template\"><h1>{{ post.title }}</h1><div>{{ post.content }}</div></article>"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft Post",
               content: "**Draft** preview body",
               language: "en",
               template_slug: published_template.slug
             })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/draft-post", post.id)

    assert draft_html =~ "preview-template"
    assert draft_html =~ "Draft Post"
    assert draft_html =~ ~s(<strong>Draft</strong> preview body)
    refute draft_html =~ "**Draft** preview body"

    assert {:ok, published_post} = Posts.publish_post(post.id)

    published_datetime = DateTime.from_unix!(published_post.created_at, :millisecond)

    published_path =
      "/#{published_datetime.year}/#{String.pad_leading(Integer.to_string(published_datetime.month), 2, "0")}/#{String.pad_leading(Integer.to_string(published_datetime.day), 2, "0")}/#{published_post.slug}"

    :inets.start()

    assert {:ok, server} = BDS.Preview.start_preview(project.id)

    assert {:ok, {{_version, 200, _reason}, _headers, published_html}} =
             :httpc.request(
               :get,
               {to_charlist(
                  "http://#{server.host}:#{server.port}#{published_path}?draft=true&post_id=#{published_post.id}"
                ), []},
               [],
               body_format: :binary
             )

    assert published_html =~ ~s(<strong>Draft</strong> preview body)
    refute published_html =~ "**Draft** preview body"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "draft preview renders through copied starter templates with markdown and i18n", %{
    project: project
  } do
    assert {:ok, _menu} =
             BDS.Menu.update_menu(project.id, [
               %{kind: :page, label: "Notes", slug: "notes"}
             ])

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft Post",
               content: "**Draft** preview body",
               language: "en"
             })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/draft-post", post.id)

    assert draft_html =~ ~s(data-template="single-post")
    assert draft_html =~ ~s(<strong>Draft</strong> preview body)
    assert draft_html =~ "Language"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "draft preview honors the lang query parameter and falls back to the canonical draft", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Canonical Draft",
               content: "Canonical body",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Deutscher Entwurf",
               content: "Deutscher Inhalt"
             })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: german_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/canonical-draft?lang=de", post.id)

    assert german_html =~ ~s(<html lang="de")
    assert german_html =~ "Deutscher Entwurf"
    assert german_html =~ "Deutscher Inhalt"
    refute german_html =~ "Canonical body"

    assert {:ok, %{body: fallback_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/canonical-draft?lang=fr", post.id)

    assert fallback_html =~ ~s(<html lang="en")
    assert fallback_html =~ "Canonical Draft"
    assert fallback_html =~ "Canonical body"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "http draft preview serves published post body from the file-backed canonical route", %{
    project: project
  } do
    :inets.start()

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Published HTTP Preview",
               content: "Published body from file",
               language: "en"
             })

    assert {:ok, _published} = Posts.publish_post(post.id)
    assert {:ok, server} = BDS.Preview.start_preview(project.id)

    datetime = DateTime.from_unix!(post.created_at, :millisecond)

    request_url =
      "http://#{server.host}:#{server.port}/#{datetime.year}/#{String.pad_leading(Integer.to_string(datetime.month), 2, "0")}/#{String.pad_leading(Integer.to_string(datetime.day), 2, "0")}/#{post.slug}?draft=true&post_id=#{post.id}"

    assert {:ok, {{_version, 200, _reason}, _headers, body}} =
             :httpc.request(
               :get,
               {to_charlist(request_url), []},
               [],
               body_format: :binary
             )

    assert body =~ "Published body from file"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "preview renders not-found template for missing routes and rewrites markdown macros and canonical URLs",
       %{project: project, temp_dir: temp_dir} do
    :inets.start()

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    source_path = Path.join(temp_dir, "sample.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Sample"
             })

    assert {:ok, linked_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Linked Post",
               content: "Linked body",
               language: "en"
             })

    assert {:ok, published_linked_post} = Posts.publish_post(linked_post.id)

    media_source_reference = "/" <> Path.join(Path.dirname(media.file_path), media.original_name)

    canonical_post_href =
      "/" <>
        String.trim_trailing(BDS.Generation.post_output_path(published_linked_post), "index.html")

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft Post",
               content:
                 [
                   "[Read linked post](/posts/linked-post)",
                   "",
                   "![Asset](#{media_source_reference})",
                   "",
                   "[[youtube id=dQw4w9WgXcQ]]"
                 ]
                 |> Enum.join("\n"),
               language: "en"
             })

    assert {:ok, server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/draft-post", post.id)

    assert draft_html =~ ~s(src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0")
    assert draft_html =~ ~s(href="#{canonical_post_href}")
    assert draft_html =~ ~s(src="/#{media.file_path}")

    assert {:ok, %{body: missing_body, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/missing-page")

    assert missing_body =~ ~s(data-template="not-found")

    assert {:ok, {{_version, 404, _reason}, _headers, body}} =
             :httpc.request(
               :get,
               {to_charlist("http://#{server.host}:#{server.port}/missing-page"), []},
               [],
               body_format: :binary
             )

    assert body =~ ~s(data-template="not-found")

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "start_preview serves generated and draft routes over real HTTP on localhost", %{
    project: project
  } do
    :inets.start()

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "HTTP Draft",
               content: "Draft over HTTP",
               language: "en"
             })

    assert {:ok, server} = BDS.Preview.start_preview(project.id)

    assert {:ok, {{_version, 200, _reason}, headers, body}} =
             :httpc.request(:get, {to_charlist("http://#{server.host}:#{server.port}/"), []}, [],
               body_format: :binary
             )

    assert body =~ "<html"

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(to_string(name)) == "content-type" and
               to_string(value) =~ "text/html"
           end)

    assert {:ok, {{_version, 200, _reason}, _headers, draft_body}} =
             :httpc.request(
               :get,
               {to_charlist(
                  "http://#{server.host}:#{server.port}/draft/http-draft?post_id=#{post.id}"
                ), []},
               [],
               body_format: :binary
             )

    assert draft_body =~ "Draft over HTTP"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: published post route renders via template without generated files", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "On-Demand Post",
               content: "**Rendered** on demand",
               language: "en"
             })

    assert {:ok, published} = Posts.publish_post(post.id)
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    datetime = DateTime.from_unix!(published.created_at, :millisecond)
    y = Integer.to_string(datetime.year)
    m = String.pad_leading(Integer.to_string(datetime.month), 2, "0")
    d = String.pad_leading(Integer.to_string(datetime.day), 2, "0")

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/#{y}/#{m}/#{d}/#{published.slug}")

    assert html =~ "On-Demand Post"
    assert html =~ "<strong>Rendered</strong> on demand"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: home page renders published posts as list without generated files", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"],
               max_posts_per_page: 10
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Home Listed Post",
               content: "Listed body",
               language: "en"
             })

    assert {:ok, _published} = Posts.publish_post(post.id)
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/")

    assert html =~ "Home Listed Post"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: category archive renders filtered posts", %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Article Post",
               content: "Article body",
               language: "en",
               categories: ["article"]
             })

    assert {:ok, _published} = Posts.publish_post(post.id)
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/category/article")

    assert html =~ "Article Post"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: tag archive renders filtered posts", %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Tagged Post",
               content: "Tagged body",
               language: "en",
               tags: ["elixir"]
             })

    assert {:ok, _published} = Posts.publish_post(post.id)
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/tag/elixir")

    assert html =~ "Tagged Post"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: language-prefixed route renders with translation overlay", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "English Post",
               content: "English body",
               language: "en"
             })

    assert {:ok, _published} = Posts.publish_post(post.id)

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Deutscher Beitrag",
               content: "Deutscher Inhalt"
             })

    assert {:ok, _pub_translation} = Posts.publish_post_translation(post.id, "de")
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/de/")

    assert html =~ "Deutscher Beitrag"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: year archive renders date-filtered posts", %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Dated Post",
               content: "Dated body",
               language: "en"
             })

    assert {:ok, published} = Posts.publish_post(post.id)
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    datetime = DateTime.from_unix!(published.created_at, :millisecond)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/#{datetime.year}")

    assert html =~ "Dated Post"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: draft post (never published) is visible and uses DB content", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Pure Draft",
               content: "Draft-only content",
               language: "en"
             })

    assert post.status == :draft
    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    datetime = DateTime.from_unix!(post.created_at, :millisecond)
    y = Integer.to_string(datetime.year)
    m = String.pad_leading(Integer.to_string(datetime.month), 2, "0")
    d = String.pad_leading(Integer.to_string(datetime.day), 2, "0")

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/#{y}/#{m}/#{d}/#{post.slug}")

    assert html =~ "Pure Draft"
    assert html =~ "Draft-only content"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: published-then-edited post shows draft DB content over file", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Published Then Edited",
               content: "Original content",
               language: "en"
             })

    assert {:ok, published} = Posts.publish_post(post.id)

    {:ok, edited} =
      Posts.update_post(published.id, %{
        title: "Edited Title",
        content: "Edited draft content"
      })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    datetime = DateTime.from_unix!(edited.created_at, :millisecond)
    y = Integer.to_string(datetime.year)
    m = String.pad_leading(Integer.to_string(datetime.month), 2, "0")
    d = String.pad_leading(Integer.to_string(datetime.day), 2, "0")

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/#{y}/#{m}/#{d}/#{edited.slug}")

    assert html =~ "Edited Title"
    assert html =~ "Edited draft content"
    refute html =~ "Original content"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "on-demand rendering: draft posts appear in home listing", %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, _draft} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft In List",
               content: "Draft list body",
               language: "en"
             })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/")

    assert html =~ "Draft In List"

    assert :ok = BDS.Preview.stop_preview(project.id)
  end

  test "preview query params can override the rendered theme for generated and draft pages", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"],
               pico_theme: "blue"
             })

    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core])

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Theme Draft",
               content: "Theme body",
               language: "en"
             })

    assert {:ok, _server} = BDS.Preview.start_preview(project.id)

    assert {:ok, %{body: generated_html, content_type: "text/html"}} =
             BDS.Preview.request(project.id, "/?theme=amber&mode=dark")

    assert generated_html =~ ~s(data-theme="dark")
    assert generated_html =~ ~s(data-mode="dark")
    assert generated_html =~ ~s(/assets/pico.amber.min.css)

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(
               project.id,
               "/draft/theme-draft?theme=amber&mode=dark",
               post.id
             )

    assert draft_html =~ ~s(data-theme="dark")
    assert draft_html =~ ~s(data-mode="dark")
    assert draft_html =~ ~s(/assets/pico.amber.min.css)

    assert :ok = BDS.Preview.stop_preview(project.id)
  end
end
