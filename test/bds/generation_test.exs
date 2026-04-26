defmodule BDS.GenerationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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

    expected_paths = [
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
                 "<article class=\"post-template\"><h1>{{ post.title }}</h1><div class=\"body\">{{ post.content }}</div></article>"
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

  test "generation starter templates render localized archive headings in each output language", %{
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
      "/" <> Path.join(Path.dirname(media.file_path), media.original_name) <> "?download=1#preview"

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
      "tag/elixir/index.html",
      "2026/index.html",
      "2026/04/index.html",
      "de/category/notes/index.html",
      "de/tag/elixir/index.html",
      "de/2026/index.html",
      "de/2026/04/index.html"
    ]

    assert expected_paths -- Enum.map(result.generated_files, & &1.relative_path) == []

    assert File.read!(Path.join([temp_dir, "html", "category", "notes", "index.html"])) =~
             "Archive 1"

    assert File.read!(
             Path.join([temp_dir, "html", "category", "notes", "page", "2", "index.html"])
           ) =~ "Archive 3"

    assert File.read!(Path.join([temp_dir, "html", "tag", "elixir", "index.html"])) =~ "Elixir"
    assert File.read!(Path.join([temp_dir, "html", "2026", "04", "index.html"])) =~ "2026-04"
  end

  test "validate_site reports missing, extra, and stale generated pages and apply_validation repairs them",
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
    index_path = Path.join([temp_dir, "html", "index.html"])
    post_file_path = Path.join([temp_dir, "html", post_path])
    extra_path = Path.join([temp_dir, "html", "obsolete.html"])

    File.write!(index_path, "<html>tampered</html>")
    File.rm!(post_file_path)
    File.write!(extra_path, "<html>obsolete</html>")

    assert {:ok, report} = BDS.Generation.validate_site(project.id)

    assert "index.html" in report.stale_pages
    assert post_path in report.missing_pages
    assert "obsolete.html" in report.extra_pages

    assert {:ok, repair} = BDS.Generation.apply_validation(project.id, [:core, :single])
    assert Enum.sort(repair.sections) == [:core, :single]

    assert File.read!(index_path) != "<html>tampered</html>"
    assert File.exists?(post_file_path)
    refute File.exists?(extra_path)

    assert {:ok, clean_report} = BDS.Generation.validate_site(project.id, [:core, :single])
    assert clean_report.missing_pages == []
    assert clean_report.extra_pages == []
    assert clean_report.stale_pages == []
  end
end
