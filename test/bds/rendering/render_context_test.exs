defmodule BDS.Rendering.RenderContextTest do
  use ExUnit.Case, async: false

  alias BDS.Generation
  alias BDS.Rendering
  alias BDS.Rendering.RenderContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-render-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "RenderContext", data_path: temp_dir})

    {:ok, _metadata} =
      BDS.Metadata.update_project_metadata(project.id, %{
        main_language: "en",
        blog_languages: ["en", "de"]
      })

    %{project: project, temp_dir: temp_dir}
  end

  defp create_published_post(project, attrs) do
    {:ok, post} =
      BDS.Posts.create_post(
        Map.merge(
          %{project_id: project.id, language: "en", content: "Body"},
          attrs
        )
      )

    {:ok, published} = BDS.Posts.publish_post(post.id)
    published
  end

  test "build/1 preloads canonical paths, menu, tag colors, and link maps", %{project: project} do
    target = create_published_post(project, %{title: "Ctx Target", tags: ["alpha"]})

    _source =
      create_published_post(project, %{
        title: "Ctx Source",
        content: "See [Target](/#{Enum.join(post_date_parts(target), "/")}/#{target.slug}/)"
      })

    ctx = RenderContext.build(project.id)

    assert ctx.project.id == project.id
    assert ctx.main_language == "en"
    assert Map.has_key?(ctx.canonical_post_paths, target.slug)
    assert is_map(ctx.canonical_media_paths)
    assert is_map(ctx.tag_color_by_name)
    assert is_list(ctx.menu_items)

    incoming = Map.get(ctx.incoming_links_by_post, target.id, [])
    assert Enum.any?(incoming, fn link -> link.title == "Ctx Source" end)
  end

  test "memoize/3 executes the computation only once per key", %{project: project} do
    ctx = RenderContext.build(project.id)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn ->
      Agent.update(counter, &(&1 + 1))
      :computed
    end

    assert RenderContext.memoize(ctx, {:test, "key"}, compute) == :computed
    assert RenderContext.memoize(ctx, {:test, "key"}, compute) == :computed
    assert Agent.get(counter, & &1) == 1
  end

  test "memoize/3 computes once even under concurrent first calls", %{project: project} do
    ctx = RenderContext.build(project.id)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    slow_compute = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(30)
      :computed
    end

    results =
      1..8
      |> Task.async_stream(
        fn _index -> RenderContext.memoize(ctx, {:test, "concurrent"}, slow_compute) end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.all?(results, &(&1 == :computed))
    assert Agent.get(counter, & &1) == 1
  end

  test "render_post_page with a context matches the project_id render", %{project: project} do
    {:ok, template} =
      BDS.Templates.create_template(%{
        project_id: project.id,
        title: "Ctx Parity",
        kind: :post,
        content:
          "{{ page_title }}|{{ post.author }}|{{ post.tags.size }}|{% for lang in blog_languages %}[{{ lang.code }}]{% endfor %}|{{ content }}"
      })

    {:ok, published_template} = BDS.Templates.publish_template(template.id)

    post =
      create_published_post(project, %{
        title: "Parity Post",
        author: "Writer",
        tags: ["alpha", "beta"],
        content: "Hello **world**",
        template_slug: published_template.slug
      })

    assigns = %{
      id: post.id,
      title: post.title,
      content: "Hello **world**",
      slug: post.slug,
      language: "en",
      excerpt: post.excerpt,
      template_slug: post.template_slug
    }

    assert {:ok, from_project_id} =
             Rendering.render_post_page(project.id, published_template.slug, assigns)

    ctx = RenderContext.build(project.id)

    assert {:ok, from_ctx} =
             Rendering.render_post_page(ctx, published_template.slug, assigns)

    assert from_ctx == from_project_id
  end

  test "render_list_page with a context matches the project_id render", %{project: project} do
    post = create_published_post(project, %{title: "List Parity", content: "List body"})

    assigns = %{
      language: "en",
      page_title: "Home",
      posts: [
        %{
          id: post.id,
          slug: post.slug,
          title: post.title,
          href: "/#{post.slug}/",
          excerpt: post.excerpt,
          content: "List body"
        }
      ],
      archive_context: %{kind: "core"},
      pagination: %{
        current_page: 1,
        total_pages: 1,
        total_items: 1,
        items_per_page: 10,
        has_prev_page: false,
        prev_page_href: "",
        has_next_page: false,
        next_page_href: ""
      }
    }

    assert {:ok, from_project_id} = Rendering.render_list_page(project.id, assigns)

    ctx = RenderContext.build(project.id)
    assert {:ok, from_ctx} = Rendering.render_list_page(ctx, assigns)

    assert from_ctx == from_project_id
  end

  test "render_template caches the parsed template AST in the context", %{project: project} do
    ctx = RenderContext.build(project.id)
    source = "Hello {{ name }}"

    assert {:ok, "Hello A"} =
             BDS.Rendering.TemplateSelection.render_template(ctx, source, %{"name" => "A"})

    assert {:ok, "Hello B"} =
             BDS.Rendering.TemplateSelection.render_template(ctx, source, %{"name" => "B"})

    ast_entries =
      :ets.tab2list(ctx.cache)
      |> Enum.filter(fn {key, _value} -> match?({:template_ast, _hash}, key) end)

    assert length(ast_entries) == 1
  end

  test "load_body caches post bodies for the lifetime of the context", %{
    project: project,
    temp_dir: temp_dir
  } do
    relative_path = "posts/cached-body.md"
    full_path = Path.join(temp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, "---\ntitle: Cached\n---\nCached body content\n")

    ctx = RenderContext.build(project.id)

    assert BDS.Generation.Renderers.load_body(ctx, relative_path, nil) ==
             "Cached body content"

    File.rm!(full_path)

    assert BDS.Generation.Renderers.load_body(ctx, relative_path, nil) ==
             "Cached body content"
  end

  test "generate_site batches hash bookkeeping and skips unchanged outputs", %{
    project: project,
    temp_dir: temp_dir
  } do
    _post = create_published_post(project, %{title: "Site Post", content: "Site body"})

    assert {:ok, %{generated_files: files}} =
             Generation.generate_site(project.id, [:core, :single])

    assert files != []

    Enum.each(files, fn file ->
      disk_path = Path.join([temp_dir, "html", file.relative_path])
      assert File.exists?(disk_path)

      disk_hash =
        :crypto.hash(:sha256, File.read!(disk_path)) |> Base.encode16(case: :lower)

      assert disk_hash == file.content_hash
    end)

    first_by_path = Map.new(files, &{&1.relative_path, &1})

    Process.sleep(5)

    assert {:ok, %{generated_files: second_files}} =
             Generation.generate_site(project.id, [:core, :single])

    Enum.each(second_files, fn file ->
      first = Map.fetch!(first_by_path, file.relative_path)
      assert file.content_hash == first.content_hash

      assert file.updated_at == first.updated_at,
             "expected unchanged output #{file.relative_path} to keep its updated_at"
    end)
  end

  test "force render rewrites outputs whose stored hash still matches", %{
    project: project,
    temp_dir: temp_dir
  } do
    post = create_published_post(project, %{title: "Force Post", content: "Force body"})

    assert {:ok, _} = Generation.render_site_section(project.id, :single)

    post_file = Path.join([temp_dir, "html", Generation.post_output_path(post)])
    original_html = File.read!(post_file)
    File.write!(post_file, "TAMPERED")

    # A normal render trusts the stored hash and leaves the drifted file alone.
    assert {:ok, _} = Generation.render_site_section(project.id, :single)
    assert File.read!(post_file) == "TAMPERED"

    # A forced render ignores the stored hashes and rewrites everything.
    assert {:ok, _} = Generation.render_site_section(project.id, :single, force: true)
    assert File.read!(post_file) == original_html
  end

  test "full section render issues a bounded number of queries regardless of post count", %{
    project: project
  } do
    for index <- 1..12 do
      create_published_post(project, %{
        title: "Query Bound #{index}",
        content: "Body #{index}",
        tags: ["tag-#{rem(index, 3)}"],
        categories: ["article"]
      })
    end

    query_count =
      count_queries(fn ->
        assert {:ok, %{rendered_url_count: rendered}} =
                 Generation.render_site_section(project.id, :single)

        assert rendered >= 12
      end)

    # Before the render-context rework this was ~15 queries *per page*; the
    # bound only holds if all per-page lookups stay preloaded.
    assert query_count <= 40,
           "expected a bounded query count for the section render, got #{query_count}"
  end

  defp count_queries(func) do
    test_pid = self()
    ref = make_ref()
    handler_id = "render-context-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:bds, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:query_executed, ref})
      end,
      nil
    )

    func.()
    :telemetry.detach(handler_id)
    count_query_messages(ref, 0)
  end

  defp count_query_messages(ref, acc) do
    receive do
      {:query_executed, ^ref} -> count_query_messages(ref, acc + 1)
    after
      0 -> acc
    end
  end

  defp post_date_parts(post) do
    datetime = BDS.Persistence.from_unix_ms!(post.created_at)

    [
      Integer.to_string(datetime.year),
      String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
      String.pad_leading(Integer.to_string(datetime.day), 2, "0")
    ]
  end
end
