defmodule BDS.GenerationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.PreviewAssets
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-generation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Generation", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "write_generated_file writes under html output and skips unchanged content by hash", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, first_write} =
             BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")

    assert first_write.written? == true

    output_path = Path.join([temp_dir, "html", "index.html"])
    assert File.read!(output_path) == "<html>hello</html>"

    assert {:ok, [tracked_file]} = BDS.Generation.list_generated_files(project.id)
    assert tracked_file.relative_path == "index.html"
    assert tracked_file.content_hash == first_write.content_hash

    assert {:ok, second_write} =
             BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")

    assert second_write.written? == false
    assert second_write.content_hash == first_write.content_hash

    assert {:ok, third_write} =
             BDS.Generation.write_generated_file(project.id, "index.html", "<html>updated</html>")

    assert third_write.written? == true
    assert third_write.content_hash != first_write.content_hash
    assert File.read!(output_path) == "<html>updated</html>"
  end

  test "delete_generated_file removes tracked output and forgets its hash", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _write} =
             BDS.Generation.write_generated_file(
               project.id,
               "tag/elixir/index.html",
               "<html>tag</html>"
             )

    output_path = Path.join([temp_dir, "html", "tag", "elixir", "index.html"])
    assert File.exists?(output_path)

    assert :ok = BDS.Generation.delete_generated_file(project.id, "tag/elixir/index.html")
    refute File.exists?(output_path)

    assert {:ok, files} = BDS.Generation.list_generated_files(project.id)
    assert files == []
  end

  test "plan_generation derives generation settings from project metadata and core generation writes tracked files",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"],
               max_posts_per_page: 25,
               pico_theme: "amber"
             })

    assert {:ok, plan} = BDS.Generation.plan_generation(project.id, [:core])
    assert plan.project_id == project.id
    assert plan.base_url == "https://example.com/blog"
    assert plan.language == "en"
    assert plan.blog_languages == ["en", "de"]
    assert plan.max_posts_per_page == 25
    assert plan.pico_theme == "amber"
    assert plan.sections == [:core]
    assert plan.generated_files == []

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core])
    assert result.sections == [:core]

    expected_paths =
      [
        "404.html",
        "index.html",
        "sitemap.xml",
        "feed.xml",
        "atom.xml",
        "calendar.json",
        "pagefind/index.json",
        "pagefind/pagefind-ui.css",
        "pagefind/pagefind-ui.js",
        "de/404.html",
        "de/index.html",
        "de/feed.xml",
        "de/atom.xml",
        "de/pagefind/index.json",
        "de/pagefind/pagefind-ui.css",
        "de/pagefind/pagefind-ui.js"
      ] ++ Enum.map(PreviewAssets.generated_outputs(), &elem(&1, 0))

    assert Enum.sort(Enum.map(result.generated_files, & &1.relative_path)) ==
             Enum.sort(expected_paths)

    for relative_path <- expected_paths do
      assert File.exists?(Path.join([temp_dir, "html", relative_path]))
    end

    assert File.read!(Path.join([temp_dir, "html", "sitemap.xml"])) =~ "https://example.com/blog/"
  end

  test "core generation writes local macro and preview assets for static html", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"],
               pico_theme: "green"
             })

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core])

    expected_assets = [
      "assets/pico.min.css",
      "assets/pico.green.min.css",
      "assets/lightbox.min.css",
      "assets/lightbox.min.js",
      "assets/highlight.min.css",
      "assets/highlight.min.js",
      "assets/code-enhancements.js",
      "assets/d3.layout.cloud.js",
      "assets/tag-cloud.js",
      "assets/vanilla-calendar.min.css",
      "assets/vanilla-calendar.min.js",
      "assets/calendar-runtime.js",
      "assets/search-runtime.js",
      "assets/bds.css",
      "images/prev.png",
      "images/next.png",
      "images/close.png",
      "images/loading.gif"
    ]

    generated_paths = Enum.map(result.generated_files, & &1.relative_path)

    for relative_path <- expected_assets do
      assert relative_path in generated_paths
      assert File.exists?(Path.join([temp_dir, "html", relative_path]))
    end

    assert File.read!(Path.join([temp_dir, "html", "assets", "calendar-runtime.js"])) =~
             "loadCalendarData"

    assert File.read!(Path.join([temp_dir, "html", "assets", "tag-cloud.js"])) =~
             "data-tag-cloud-words"

    assert File.read!(Path.join([temp_dir, "html", "assets", "bds.css"])) =~ ".blog-menu"

    assert File.read!(Path.join([temp_dir, "html", "assets", "pico.green.min.css"])) =~
             "color-scheme"
  end

  test "generation writes feed and atom entries with canonical URLs for published posts", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Feed Entry",
               content: "Feed body",
               language: "en"
             })

    created_at = DateTime.to_unix(~U[2026-04-15 12:00:00Z])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: created_at, updated_at: created_at]
    )

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core, :single])

    canonical_url =
      "https://example.com/blog" <>
        "/" <> String.trim_trailing(BDS.Generation.post_output_path(published_post), "index.html")

    feed_xml = File.read!(Path.join([temp_dir, "html", "feed.xml"]))
    atom_xml = File.read!(Path.join([temp_dir, "html", "atom.xml"]))

    assert feed_xml =~ "<rss>"
    assert feed_xml =~ "<item><title>Feed Entry</title><link>#{canonical_url}</link></item>"

    assert atom_xml =~ "<feed>"
    assert atom_xml =~ "<entry><title>Feed Entry</title><id>#{canonical_url}</id></entry>"
  end

  test "generation renders published list and post templates for core and single pages", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, list_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "List View",
               kind: :list,
               content:
                 "<main class=\"list-template\"><h1>{{ page_title }}</h1>{% for post in posts %}<a href=\"{{ post.href }}\">{{ post.title }}</a>{% endfor %}</main>"
             })

    assert {:ok, _published_list} = BDS.Templates.publish_template(list_template.id)

    assert {:ok, post_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Post View",
               kind: :post,
               content:
                 "<article class=\"post-template\" data-pagefind-body><h1>{{ post.title }}</h1><div class=\"body\">{{ post.content }}</div></article>"
             })

    assert {:ok, published_post_template} = BDS.Templates.publish_template(post_template.id)

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Rendered Post",
               content: "**Rendered** body",
               language: "en",
               template_slug: published_post_template.slug
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core, :single])

    post_path = BDS.Generation.post_output_path(published_post)
    relative_paths = Enum.map(result.generated_files, & &1.relative_path)

    assert "index.html" in relative_paths
    assert post_path in relative_paths

    index_html = File.read!(Path.join([temp_dir, "html", "index.html"]))
    assert index_html =~ "list-template"
    assert index_html =~ "Rendered Post"

    post_html = File.read!(Path.join([temp_dir, "html", post_path]))
    assert post_html =~ "post-template"
    assert post_html =~ ~s(<strong>Rendered</strong> body)
    refute post_html =~ "**Rendered** body"

    assert "pagefind/index.json" in relative_paths
    assert "pagefind/pagefind-ui.js" in relative_paths
    assert "de/pagefind/index.json" in relative_paths

    pagefind_index =
      Path.join([temp_dir, "html", "pagefind", "index.json"])
      |> File.read!()
      |> Jason.decode!()

    assert pagefind_index["language"] == "en"
    assert Enum.any?(pagefind_index["pages"], &(&1["url"] == "/#{post_path}"))

    de_pagefind_index =
      Path.join([temp_dir, "html", "de", "pagefind", "index.json"])
      |> File.read!()
      |> Jason.decode!()

    assert de_pagefind_index["language"] == "de"
  end

  test "generation renders copied starter templates with partials, i18n, and markdown", %{
    project: project,
    temp_dir: temp_dir
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
               title: "Starter Rendered Post",
               content: "**Rendered** body",
               language: "en",
               categories: ["notes"],
               tags: ["Elixir"]
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core, :single])

    post_path = BDS.Generation.post_output_path(published_post)
    relative_paths = Enum.map(result.generated_files, & &1.relative_path)

    assert "index.html" in relative_paths
    assert post_path in relative_paths

    index_html = File.read!(Path.join([temp_dir, "html", "index.html"]))
    assert index_html =~ ~s(<nav class="blog-menu">)
    assert index_html =~ ~s(/assets/pico.min.css)
    assert index_html =~ "Starter Rendered Post"

    post_html = File.read!(Path.join([temp_dir, "html", post_path]))
    assert post_html =~ ~s(data-template="single-post")
    assert post_html =~ ~s(<strong>Rendered</strong> body)
    assert post_html =~ "Taxonomy"
    assert post_html =~ "Language"
  end

  test "validate_site does not crash on unknown macros with quoted params", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Gallery Macro Post",
               content: "[[gallery link=\"file\"]]",
               language: "en"
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core, :single])

    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:core, :single])
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
  end

  test "validate_site reports old-app phase progress", %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Progress Post",
               content: "Progress body",
               language: "en"
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)

    parent = self()

    on_progress = fn value, message ->
      send(parent, {:validate_progress, value, message})
    end

    assert {:ok, _report} =
             BDS.Generation.validate_site(project.id, [:core, :single], on_progress: on_progress)

    events = collect_validate_progress_events()

    assert {0.0, "Collecting sitemap URLs..."} in events

    assert Enum.any?(events, fn
             {value, message}
             when is_number(value) and value > 0.0 and value < 0.5 and
                    is_binary(message) ->
               String.starts_with?(message, "Collecting sitemap URLs")

             _other ->
               false
           end)

    assert {0.5, "Comparing sitemap to html pages..."} in events

    assert Enum.any?(events, fn
             {value, message}
             when is_number(value) and value > 0.5 and value < 1.0 and is_binary(message) ->
               String.starts_with?(message, "Comparing sitemap to html pages")

             _other ->
               false
           end)

    assert Enum.any?(events, fn
             {1.0, message} -> String.starts_with?(message, "Validation complete (")
             _other -> false
           end)
  end

  test "validate_site does not emit markdown parser warnings for unclosed fenced blocks", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Malformed Markdown",
               content: "```elixir\nIO.puts(:broken)",
               language: "en"
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, _report} = BDS.Generation.validate_site(project.id, [:core, :single])
      end)

    assert stderr == ""
  end

  test "generation falls back to bundled default templates when the project has no template files or template rows",
       %{project: project, temp_dir: temp_dir} do
    File.rm_rf!(Path.join(temp_dir, "templates"))

    Repo.delete_all(
      from template in BDS.Templates.Template,
        where: template.project_id == ^project.id
    )

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
               title: "Bundled Rendered Post",
               content: "**Rendered** body",
               language: "en",
               categories: ["notes"],
               tags: ["Elixir"]
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core, :single])

    post_path = BDS.Generation.post_output_path(published_post)
    relative_paths = Enum.map(result.generated_files, & &1.relative_path)

    assert "index.html" in relative_paths
    assert post_path in relative_paths

    index_html = File.read!(Path.join([temp_dir, "html", "index.html"]))
    assert index_html =~ ~s(<nav class="blog-menu">)
    assert index_html =~ ~s(/assets/pico.min.css)
    assert index_html =~ "Bundled Rendered Post"

    post_html = File.read!(Path.join([temp_dir, "html", post_path]))
    assert post_html =~ ~s(data-template="single-post")
    assert post_html =~ ~s(<strong>Rendered</strong> body)
    assert post_html =~ "Taxonomy"
    assert post_html =~ "Language"
  end

  test "generation expands starter-template markdown macros, rewrites canonical post links, media links, and emits not-found page",
       %{project: project, temp_dir: temp_dir} do
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
               title: "Rendered Post",
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

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core, :single])

    assert "404.html" in Enum.map(result.generated_files, & &1.relative_path)

    post_html =
      File.read!(Path.join([temp_dir, "html", BDS.Generation.post_output_path(published_post)]))

    assert post_html =~ ~s(src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0")
    assert post_html =~ ~s(href="#{canonical_post_href}")
    assert post_html =~ ~s(src="/#{media.file_path}")

    not_found_html = File.read!(Path.join([temp_dir, "html", "404.html"]))
    assert not_found_html =~ ~s(data-template="not-found")
    assert not_found_html =~ "Back to preview home"
  end

  test "generation starter templates render localized archive headings in each output language",
       %{
         project: project,
         temp_dir: temp_dir
       } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "fr",
               blog_languages: ["fr", "en"],
               max_posts_per_page: 10
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Archive Heading",
               content: "Archive body",
               language: "fr"
             })

    created_at = DateTime.to_unix(~U[2026-02-15 12:00:00Z])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: created_at, updated_at: created_at]
    )

    assert {:ok, _published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:date])

    french_html = File.read!(Path.join([temp_dir, "html", "2026", "02", "index.html"]))
    english_html = File.read!(Path.join([temp_dir, "html", "en", "2026", "02", "index.html"]))

    assert french_html =~ ~s(<html lang="fr")
    assert french_html =~ "Archives février 2026"

    assert english_html =~ ~s(<html lang="en")
    assert english_html =~ "Archive February 2026"
  end

  test "generation rewrites media aliases with suffixes and renders slugged taxonomy links with tag colors",
       %{project: project, temp_dir: temp_dir} do
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

    media_source_reference =
      "/" <>
        Path.join(Path.dirname(media.file_path), media.original_name) <> "?download=1#preview"

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Taxonomy Colors",
               content: "![Asset](#{media_source_reference})",
               language: "en",
               categories: ["Release Notes"],
               tags: ["Elixir"]
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, [tag]} = BDS.Tags.sync_tags_from_posts(project.id)
    assert {:ok, _updated_tag} = BDS.Tags.update_tag(tag.id, %{color: "#112233"})
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:single])

    post_html =
      File.read!(Path.join([temp_dir, "html", BDS.Generation.post_output_path(published_post)]))

    category_link = ~s(href="/category/release-notes/")
    tag_link = ~s(href="/tag/elixir/" style="--bubble-accent: #112233;")

    assert post_html =~ category_link
    assert post_html =~ tag_link

    assert elem(:binary.match(post_html, category_link), 0) <
             elem(:binary.match(post_html, tag_link), 0)

    assert post_html =~ ~s(src="/#{media.file_path}?download=1#preview")
  end

  test "single generation writes canonical post pages and language-prefixed translation pages", %{
    project: project,
    temp_dir: temp_dir
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
               title: "My Post",
               content: "Hello generated world",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Mein Beitrag",
               content: "Hallo generierte Welt"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:single])

    post_path = BDS.Generation.post_output_path(published_post)
    translation_path = BDS.Generation.post_output_path(published_post, "de")

    assert Enum.map(result.generated_files, & &1.relative_path) |> Enum.sort() ==
             Enum.sort([post_path, translation_path])

    assert File.read!(Path.join([temp_dir, "html", post_path])) =~ "Hello generated world"
    assert File.read!(Path.join([temp_dir, "html", translation_path])) =~ "Hallo generierte Welt"
    assert File.read!(Path.join([temp_dir, "html", post_path])) =~ ~s(data-pagefind-body)
  end

  test "single generation renders the canonical route in the project main language when a translation exists",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "fr",
               blog_languages: ["fr", "en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Hello World",
               content: "Canonical body",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "fr", %{
               title: "Bonjour le monde",
               content: "Corps FR"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:single])

    post_path = BDS.Generation.post_output_path(published_post)
    translation_path = BDS.Generation.post_output_path(published_post, "en")

    assert Enum.map(result.generated_files, & &1.relative_path) |> Enum.sort() ==
             Enum.sort([post_path, translation_path])

    canonical_html = File.read!(Path.join([temp_dir, "html", post_path]))
    english_html = File.read!(Path.join([temp_dir, "html", translation_path]))

    assert canonical_html =~ ~s(<html lang="fr")
    assert canonical_html =~ "Bonjour le monde"
    assert canonical_html =~ "Corps FR"
    refute canonical_html =~ "Canonical body"

    assert english_html =~ ~s(<html lang="en")
    assert english_html =~ "Hello World"
    assert english_html =~ "Canonical body"
  end

  test "single generation uses host local calendar date for dated output paths", %{
    project: project,
    temp_dir: temp_dir
  } do
    created_at = DateTime.to_unix(~U[2010-11-16 23:26:04Z], :millisecond)
    {{year, month, day}, _time} = :calendar.system_time_to_local_time(created_at, :millisecond)

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Umzugsstatus",
               content: "Local date body",
               language: "de"
             })

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: created_at, published_at: created_at, updated_at: created_at]
    )

    assert {:ok, _published} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:single])

    expected_path =
      Path.join([
        Integer.to_string(year),
        String.pad_leading(Integer.to_string(month), 2, "0"),
        String.pad_leading(Integer.to_string(day), 2, "0"),
        "umzugsstatus",
        "index.html"
      ])

    assert expected_path in Enum.map(result.generated_files, & &1.relative_path)
    assert File.exists?(Path.join([temp_dir, "html", expected_path]))
  end

  test "archive generation writes paginated category, tag, and date pages", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"],
               max_posts_per_page: 2
             })

    for index <- 1..3 do
      assert {:ok, post} =
               Posts.create_post(%{
                 project_id: project.id,
                 title: "Archive #{index}",
                 content: "Archive body #{index}",
                 language: "en",
                 categories: ["notes"],
                 tags: ["Elixir"]
               })

      created_at = DateTime.to_unix(~U[2026-04-15 12:00:00Z]) + index

      Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
        set: [created_at: created_at, updated_at: created_at]
      )

      assert {:ok, _published} = Posts.publish_post(post.id)
    end

    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:category, :tag, :date])

    expected_paths = [
      "category/notes/index.html",
      "category/notes/page/2/index.html",
      "tag/Elixir/index.html",
      "2026/index.html",
      "2026/04/index.html",
      "de/category/notes/index.html",
      "de/tag/Elixir/index.html",
      "de/2026/index.html",
      "de/2026/04/index.html"
    ]

    assert expected_paths -- Enum.map(result.generated_files, & &1.relative_path) == []

    assert File.read!(Path.join([temp_dir, "html", "category", "notes", "index.html"])) =~
             "Archive 1"

    assert File.read!(
             Path.join([temp_dir, "html", "category", "notes", "page", "2", "index.html"])
           ) =~ "Archive 3"

    assert File.read!(Path.join([temp_dir, "html", "tag", "Elixir", "index.html"])) =~ "Elixir"
    assert File.read!(Path.join([temp_dir, "html", "2026", "04", "index.html"])) =~ "2026-04"
  end

  test "validate_site reports missing, extra, and updated routes and apply_validation repairs them",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Validation Post",
               content: "Validation body",
               language: "en"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core, :single])

    post_path = BDS.Generation.post_output_path(published_post)
    post_file_path = Path.join([temp_dir, "html", post_path])
    source_path = Path.join([temp_dir, published_post.file_path])
    extra_path = Path.join([temp_dir, "html", "obsolete", "index.html"])

    backdate_generated_outputs(project.id, temp_dir)
    File.rm!(post_file_path)
    File.write!(source_path, File.read!(source_path) <> "\n")
    File.mkdir_p!(Path.dirname(extra_path))
    File.write!(extra_path, "<html>obsolete</html>")

    assert {:ok, report} = BDS.Generation.validate_site(project.id)

    assert relative_path_to_url_path(post_path) in report.missing_url_paths
    assert "/obsolete" in report.extra_url_paths
    assert report.updated_post_url_paths == []

    assert {:ok, repair} = BDS.Generation.apply_validation(project.id, report)
    assert repair.rendered_url_count > 0

    assert File.exists?(post_file_path)
    refute File.exists?(extra_path)

    assert {:ok, clean_report} = BDS.Generation.validate_site(project.id)
    assert clean_report.missing_url_paths == []
    assert clean_report.extra_url_paths == []
    assert clean_report.updated_post_url_paths == []
  end

  test "apply_validation renders only targeted routes and leaves feed/atom/404/pagefind untouched",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post_a} =
             Posts.create_post(%{
               project_id: project.id,
               title: "First Post",
               content: "First body",
               language: "en"
             })

    assert {:ok, _published_a} = Posts.publish_post(post_a.id)

    assert {:ok, _result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    feed_path = Path.join([temp_dir, "html", "feed.xml"])
    atom_path = Path.join([temp_dir, "html", "atom.xml"])
    not_found_path = Path.join([temp_dir, "html", "404.html"])
    pagefind_path = Path.join([temp_dir, "html", "pagefind", "index.json"])

    feed_before = File.read!(feed_path)
    atom_before = File.read!(atom_path)
    not_found_before = File.read!(not_found_path)
    pagefind_before = File.read!(pagefind_path)

    # Publishing a new post leaves the generated feed/index reflecting only post A
    # until validation apply targets the newly missing routes.
    assert {:ok, post_b} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Second Post",
               content: "Second body",
               language: "en"
             })

    assert {:ok, published_b} = Posts.publish_post(post_b.id)

    post_b_path = BDS.Generation.post_output_path(published_b)
    post_b_file = Path.join([temp_dir, "html", post_b_path])
    refute File.exists?(post_b_file)

    assert {:ok, report} = BDS.Generation.validate_site(project.id)
    assert relative_path_to_url_path(post_b_path) in report.missing_url_paths

    assert {:ok, repair} = BDS.Generation.apply_validation(project.id, report)
    assert repair.rendered_url_count > 0

    # The targeted single-post route is rendered.
    assert File.exists?(post_b_file)

    # Old-app parity: feed, atom, 404, and the search index are NOT regenerated on apply.
    assert File.read!(feed_path) == feed_before
    assert File.read!(atom_path) == atom_before
    assert File.read!(not_found_path) == not_found_before
    assert File.read!(pagefind_path) == pagefind_before
  end

  test "apply_validation re-renders only the affected post's categories, tags, and single route",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post_a} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Alpha",
               content: "Alpha body",
               language: "en",
               categories: ["notes"],
               tags: ["elixir"]
             })

    assert {:ok, published_a} = Posts.publish_post(post_a.id)

    assert {:ok, post_b} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Beta",
               content: "Beta body",
               language: "en",
               categories: ["photos"],
               tags: ["erlang"]
             })

    assert {:ok, published_b} = Posts.publish_post(post_b.id)

    assert {:ok, _result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    post_a_path = BDS.Generation.post_output_path(published_a)
    post_b_path = BDS.Generation.post_output_path(published_b)

    notes_before = generated_updated_at(project.id, "category/notes/index.html")
    elixir_before = generated_updated_at(project.id, "tag/elixir/index.html")
    photos_before = generated_updated_at(project.id, "category/photos/index.html")
    erlang_before = generated_updated_at(project.id, "tag/erlang/index.html")
    post_b_before = generated_updated_at(project.id, post_b_path)

    File.rm!(Path.join([temp_dir, "html", post_a_path]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id)
    assert relative_path_to_url_path(post_a_path) in report.missing_url_paths
    # Only post A's route is affected; post B must not be flagged as updated.
    assert report.updated_post_url_paths == []

    assert {:ok, _repair} = BDS.Generation.apply_validation(project.id, report)

    # Post A's own single route plus only its category and tag archives are re-rendered.
    assert File.exists?(Path.join([temp_dir, "html", post_a_path]))
    assert generated_updated_at(project.id, "category/notes/index.html") > notes_before
    assert generated_updated_at(project.id, "tag/elixir/index.html") > elixir_before

    # Post B's single route and its unrelated category and tag archives are left untouched.
    assert generated_updated_at(project.id, post_b_path) == post_b_before
    assert generated_updated_at(project.id, "category/photos/index.html") == photos_before
    assert generated_updated_at(project.id, "tag/erlang/index.html") == erlang_before
  end

  test "apply_validation streams one progress message per rewritten URL with a running count",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Progress Post",
               content: "Progress body",
               language: "en",
               categories: ["notes"],
               tags: ["elixir"]
             })

    assert {:ok, published} = Posts.publish_post(post.id)

    assert {:ok, _result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    post_path = BDS.Generation.post_output_path(published)
    File.rm!(Path.join([temp_dir, "html", post_path]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id)

    test_pid = self()

    assert {:ok, _repair} =
             BDS.Generation.apply_validation(project.id, report,
               on_progress: fn progress, message ->
                 send(test_pid, {:progress, progress, message})
               end
             )

    messages = collect_progress_messages([])
    post_url = relative_path_to_url_path(post_path)

    # The rewritten single-post URL is named in a progress message (like the old app).
    assert Enum.any?(messages, fn {_progress, message} -> String.contains?(message, post_url) end)

    # Progress messages carry a running "(rewritten/total)" count of URLs.
    assert Enum.any?(messages, fn {_progress, message} -> message =~ ~r/\(\d+\/\d+\)/ end)

    # Progress advances incrementally rather than jumping straight from 0.0 to 1.0.
    fractions =
      messages
      |> Enum.map(fn {progress, _message} -> progress end)
      |> Enum.filter(fn progress -> progress > 0.0 and progress < 1.0 end)

    assert fractions != []
  end

  test "prepare_validation_apply classifies page and day archive routes without section fallback",
       %{project: project} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, page} =
             Posts.create_post(%{
               project_id: project.id,
               title: "About",
               content: "About body",
               language: "en",
               categories: ["page"]
             })

    assert {:ok, published_page} = Posts.publish_post(page.id)

    assert {:ok, dated_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Day Archive Source",
               content: "Day archive body",
               language: "en"
             })

    assert {:ok, published_dated_post} = Posts.publish_post(dated_post.id)

    {year, month, day} =
      published_dated_post.created_at
      |> DateTime.from_unix!(:millisecond)
      |> then(&{&1.year, &1.month, &1.day})

    assert {:ok, page_preparation} =
             BDS.Generation.prepare_validation_apply(project.id, %{
               missing_url_paths: ["/#{published_page.slug}"],
               updated_post_url_paths: [],
               extra_url_paths: []
             })

    assert page_preparation.sections_to_render == [:core]

    assert {:ok, day_preparation} =
             BDS.Generation.prepare_validation_apply(project.id, %{
               missing_url_paths: [
                 "/#{year}/#{String.pad_leading(Integer.to_string(month), 2, "0")}/#{String.pad_leading(Integer.to_string(day), 2, "0")}"
               ],
               updated_post_url_paths: [],
               extra_url_paths: []
             })

    assert day_preparation.sections_to_render == [:date]
  end

  test "apply_validation_section reports visible progress before section rendering starts", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Section Progress Template",
               kind: :post,
               content: "{{ labels.site_search_label }}: {{ post.title }}"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    published_posts =
      Enum.map(1..3, fn index ->
        assert {:ok, post} =
                 Posts.create_post(%{
                   project_id: project.id,
                   title: "Section Progress Post #{index}",
                   content: "Section progress body #{index}",
                   template_slug: published_template.slug
                 })

        assert {:ok, published_post} = Posts.publish_post(post.id)
        published_post
      end)

    post_url_paths =
      Enum.map(
        published_posts,
        &(BDS.Generation.post_output_path(&1) |> relative_path_to_url_path())
      )

    parent = self()

    on_progress = fn value, message ->
      send(parent, {:apply_section_progress, value, message})
    end

    assert {:ok, _result} =
             BDS.Generation.apply_validation_section(
               project.id,
               %{
                 missing_url_paths: post_url_paths,
                 updated_post_url_paths: [],
                 extra_url_paths: []
               },
               :single,
               on_progress: on_progress
             )

    assert_receive {:apply_section_progress, +0.0, "Render Single Posts"}

    assert_receive {:apply_section_progress, progress, message}
                   when progress > 0.0 and progress < 1.0 and
                          is_binary(message)

    rendered_path =
      Path.join([
        project.data_path,
        "html",
        BDS.Generation.post_output_path(List.first(published_posts))
      ])

    assert File.read!(rendered_path) =~ "Site search: Section Progress Post"
  end

  test "apply_validation returns an error for unreadable generated files", %{
    project: project,
    temp_dir: temp_dir
  } do
    unreadable_path = Path.join([temp_dir, "html", "obsolete", "index.html"])
    File.mkdir_p!(Path.dirname(unreadable_path))
    File.write!(unreadable_path, "<html>obsolete</html>")
    File.chmod!(unreadable_path, 0o000)
    on_exit(fn -> File.chmod!(unreadable_path, 0o644) end)

    assert {:error, {:read_generated_file, ^unreadable_path, :eacces}} =
             BDS.Generation.apply_validation(project.id, [:core])
  end

  test "validate_site regenerates sitemap and reports missing, extra, and updated post url paths",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, missing_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Missing Route Post",
               content: "Missing route body",
               language: "en",
               categories: ["notes"],
               tags: ["missing-tag"]
             })

    assert {:ok, updated_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Updated Route Post",
               content: "Updated route body",
               language: "en",
               categories: ["notes"],
               tags: ["updated-tag"]
             })

    assert {:ok, published_missing_post} = Posts.publish_post(missing_post.id)
    assert {:ok, published_updated_post} = Posts.publish_post(updated_post.id)

    assert {:ok, _result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    missing_post_path = BDS.Generation.post_output_path(published_missing_post)
    updated_post_path = BDS.Generation.post_output_path(published_updated_post)
    missing_post_url_path = relative_path_to_url_path(missing_post_path)
    updated_post_url_path = relative_path_to_url_path(updated_post_path)

    sitemap_path = Path.join([temp_dir, "html", "sitemap.xml"])
    missing_post_html_path = Path.join([temp_dir, "html", missing_post_path])
    updated_post_source_path = Path.join([temp_dir, published_updated_post.file_path])
    extra_route_path = Path.join([temp_dir, "html", "obsolete", "deep", "index.html"])

    backdate_generated_outputs(project.id, temp_dir)
    File.rm!(sitemap_path)
    File.rm!(missing_post_html_path)
    File.mkdir_p!(Path.dirname(extra_route_path))
    File.write!(extra_route_path, "<html>obsolete</html>")

    File.write!(updated_post_source_path, File.read!(updated_post_source_path) <> "\n")

    assert {:ok, report} = BDS.Generation.validate_site(project.id)

    assert report.sitemap_path == sitemap_path
    assert report.sitemap_changed == true
    assert File.exists?(sitemap_path)
    assert missing_post_url_path in report.missing_url_paths
    assert "/obsolete/deep" in report.extra_url_paths
    assert updated_post_url_path in report.updated_post_url_paths
    assert report.expected_url_count > 0
    assert report.existing_html_url_count > 0
  end

  test "validate_site uses published snapshot routes instead of mutable post rows", %{
    project: project
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Snapshot Route",
               content: "Snapshot route body",
               language: "en"
             })

    created_at = DateTime.to_unix(~U[2026-04-15 12:00:00Z])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: created_at, updated_at: created_at]
    )

    assert {:ok, published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core, :single, :date])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: DateTime.to_unix(~U[2026-04-16 12:00:00Z]), status: :draft]
    )

    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:core, :single, :date])
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []

    assert File.exists?(
             Path.join([
               BDS.Projects.project_data_dir(BDS.Projects.get_project!(project.id)),
               "html",
               BDS.Generation.post_output_path(published_post)
             ])
           )
  end

  test "validate_site follows old language subtree expectations and combined sitemap output", %{
    project: project,
    temp_dir: temp_dir
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
               title: "Localized Post",
               content: "Canonical body",
               language: "en"
             })

    created_at = DateTime.to_unix(~U[2026-04-15 12:00:00Z])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
      set: [created_at: created_at, updated_at: created_at]
    )

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Lokalisierter Beitrag",
               content: "Deutscher Inhalt"
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)
    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core, :single])
    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:core, :single])

    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []

    sitemap_xml = File.read!(Path.join([temp_dir, "html", "sitemap.xml"]))

    assert sitemap_xml =~ "hreflang=\"de\""
    assert sitemap_xml =~ "https://example.com/blog/de/2026/04/15/localized-post/"
    refute sitemap_xml =~ "localized-post.de"
  end

  test "generate_site and validate_site exclude do_not_translate posts from language subtree pagination",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"],
               max_posts_per_page: 1
             })

    assert {:ok, translatable_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Translatable",
               content: "Translatable body",
               language: "en"
             })

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^translatable_post.id),
      set: [
        created_at: DateTime.to_unix(~U[2026-04-15 12:00:00Z]),
        updated_at: DateTime.to_unix(~U[2026-04-15 12:00:00Z])
      ]
    )

    assert {:ok, _published_translatable} = Posts.publish_post(translatable_post.id)

    assert {:ok, do_not_translate_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Stay Local",
               content: "Only main language",
               language: "en",
               do_not_translate: true
             })

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^do_not_translate_post.id),
      set: [
        created_at: DateTime.to_unix(~U[2026-04-14 12:00:00Z]),
        updated_at: DateTime.to_unix(~U[2026-04-14 12:00:00Z])
      ]
    )

    assert {:ok, _published_do_not_translate} = Posts.publish_post(do_not_translate_post.id)

    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:core])

    refute File.exists?(Path.join([temp_dir, "html", "de", "page", "2", "index.html"]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:core])
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []
  end

  test "generate_site and validate_site use URL-encoded tag paths like old bDS", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "de",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Encoded Tag",
               content: "Encoded tag body",
               language: "de",
               tags: ["bücher"]
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)

    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:tag])

    assert File.exists?(Path.join([temp_dir, "html", "tag", "b%C3%BCcher", "index.html"]))
    refute File.exists?(Path.join([temp_dir, "html", "tag", "bucher", "index.html"]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:tag])
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []
  end

  test "generate_site and validate_site percent-encode reserved tag characters like old bDS", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "de",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Reserved Tag",
               content: "Reserved tag body",
               language: "de",
               tags: ["google+", "c#", "f#"]
             })

    assert {:ok, _published_post} = Posts.publish_post(post.id)

    assert {:ok, _result} = BDS.Generation.generate_site(project.id, [:tag])

    assert File.exists?(Path.join([temp_dir, "html", "tag", "google%2B", "index.html"]))
    assert File.exists?(Path.join([temp_dir, "html", "tag", "c%23", "index.html"]))
    assert File.exists?(Path.join([temp_dir, "html", "tag", "f%23", "index.html"]))

    refute File.exists?(Path.join([temp_dir, "html", "tag", "google+", "index.html"]))
    refute File.exists?(Path.join([temp_dir, "html", "tag", "c", "index.html"]))
    refute File.exists?(Path.join([temp_dir, "html", "tag", "f", "index.html"]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id, [:tag])
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []
  end

  test "generation and validation include old-app pagination and day archive routes", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"],
               max_posts_per_page: 2
             })

    for index <- 1..3 do
      assert {:ok, post} =
               Posts.create_post(%{
                 project_id: project.id,
                 title: "Paged #{index}",
                 content: "Paged body #{index}",
                 language: "en",
                 categories: ["notes"],
                 tags: ["Elixir"]
               })

      created_at = DateTime.to_unix(~U[2026-04-15 12:00:00Z]) + index

      Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^post.id),
        set: [created_at: created_at, updated_at: created_at]
      )

      assert {:ok, _published} = Posts.publish_post(post.id)
    end

    assert {:ok, page_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "About",
               content: "About body",
               language: "en",
               categories: ["page"]
             })

    page_created_at = DateTime.to_unix(~U[2026-04-15 13:00:00Z])

    Repo.update_all(from(p in BDS.Posts.Post, where: p.id == ^page_post.id),
      set: [created_at: page_created_at, updated_at: page_created_at]
    )

    assert {:ok, _published_page} = Posts.publish_post(page_post.id)

    assert {:ok, result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    relative_paths = Enum.map(result.generated_files, & &1.relative_path)

    assert "page/2/index.html" in relative_paths
    assert "tag/Elixir/page/2/index.html" in relative_paths
    assert "2026/04/15/index.html" in relative_paths
    assert "2026/04/15/page/2/index.html" in relative_paths
    assert "about/index.html" in relative_paths

    assert File.exists?(Path.join([temp_dir, "html", "page", "2", "index.html"]))
    assert File.exists?(Path.join([temp_dir, "html", "tag", "Elixir", "page", "2", "index.html"]))
    assert File.exists?(Path.join([temp_dir, "html", "2026", "04", "15", "index.html"]))

    assert File.exists?(
             Path.join([temp_dir, "html", "2026", "04", "15", "page", "2", "index.html"])
           )

    assert File.exists?(Path.join([temp_dir, "html", "about", "index.html"]))

    assert {:ok, report} = BDS.Generation.validate_site(project.id)
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == []
  end

  test "apply_validation clears updated post routes without rewriting unchanged html", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Stable Route Post",
               content: "Stable route body",
               language: "en",
               categories: ["notes"],
               tags: ["stable-tag"]
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, _result} =
             BDS.Generation.generate_site(project.id, [:core, :single, :category, :tag, :date])

    post_path = BDS.Generation.post_output_path(published_post)
    post_url_path = relative_path_to_url_path(post_path)
    post_html_path = Path.join([temp_dir, "html", post_path])
    post_source_path = Path.join([temp_dir, published_post.file_path])

    backdate_generated_outputs(project.id, temp_dir)
    before_stat = File.stat!(post_html_path)

    File.write!(post_source_path, File.read!(post_source_path) <> "\n")

    assert {:ok, report} = BDS.Generation.validate_site(project.id)
    assert report.missing_url_paths == []
    assert report.extra_url_paths == []
    assert report.updated_post_url_paths == [post_url_path]

    assert {:ok, apply_result} = BDS.Generation.apply_validation(project.id, report)
    assert apply_result.rendered_url_count > 0
    assert apply_result.deleted_url_count == 0

    after_stat = File.stat!(post_html_path)
    assert after_stat.mtime == before_stat.mtime

    assert {:ok, clean_report} = BDS.Generation.validate_site(project.id)
    assert clean_report.missing_url_paths == []
    assert clean_report.extra_url_paths == []
    assert clean_report.updated_post_url_paths == []
  end

  # Pushes generation timestamps and html mtimes far into the past so a
  # subsequent source-file write is newer by more than the second-granularity
  # mtime tolerance, without sleeping across real second boundaries.
  defp collect_progress_messages(acc) do
    receive do
      {:progress, progress, message} -> collect_progress_messages([{progress, message} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp generated_updated_at(project_id, relative_path) do
    BDS.Generation.GeneratedFileHash
    |> Repo.get_by(project_id: project_id, relative_path: relative_path)
    |> case do
      nil -> flunk("expected generated file hash for #{relative_path}")
      %{updated_at: updated_at} -> updated_at
    end
  end

  defp backdate_generated_outputs(project_id, temp_dir) do
    past_posix = System.os_time(:second) - 120

    Repo.update_all(
      from(g in BDS.Generation.GeneratedFileHash, where: g.project_id == ^project_id),
      set: [updated_at: past_posix * 1000]
    )

    [temp_dir, "html", "**"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(&File.touch!(&1, past_posix))
  end

  defp relative_path_to_url_path(relative_path) do
    cleaned =
      relative_path
      |> String.trim_leading("/")
      |> String.trim_trailing("index.html")
      |> String.trim_trailing("/")

    if cleaned == "" do
      "/"
    else
      "/" <> cleaned
    end
  end

  defp collect_validate_progress_events(acc \\ []) do
    receive do
      {:validate_progress, value, message} ->
        collect_validate_progress_events([{value, message} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
