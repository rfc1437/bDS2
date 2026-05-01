defmodule BDS.RenderingTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.Rendering

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-rendering-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Rendering", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "render_post_page exposes the spec post context and blog language links", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Render Post Context",
               kind: :post,
               content:
                 "{{ pico_stylesheet_href }}|{% for lang in blog_languages %}[{{ lang.code }}={{ lang.href }}:{{ lang.href_prefix }}]{% endfor %}|{{ post.author }}|{{ post.published_at }}|{{ post.created_at }}|{{ post.updated_at }}|{{ post.tags.size }}|{{ post.categories.size }}|{{ post.template_slug }}|{{ post.do_not_translate }}"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Render Me",
               content: "Body",
               author: "Writer",
               tags: ["alpha", "beta"],
               categories: ["notes"],
               language: "en",
               template_slug: published_template.slug,
               do_not_translate: true
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, rendered} =
             Rendering.render_post_page(project.id, published_template.slug, %{
               id: published_post.id,
               title: published_post.title,
               content: published_post.content || "",
               slug: published_post.slug,
               language: "de",
               excerpt: published_post.excerpt,
               template_slug: published_post.template_slug
             })

    assert rendered =~ "/assets/pico.min.css"
    assert rendered =~ "[en=/:]"
    assert rendered =~ "[de=/de/:/de]"
    assert rendered =~ "|Writer|"

    assert rendered =~
             "|#{published_post.published_at}|#{published_post.created_at}|#{published_post.updated_at}|"

    assert rendered =~ "|2|1|#{published_template.slug}|true"
  end

  test "render_post_page exposes alternate links, backlinks, and post link context", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Render Link Context",
               kind: :post,
               content:
                 "alts={% for alt in alternate_links %}[{{ alt.hreflang }}={{ alt.href }}]{% endfor %}|backlinks={% for backlink in backlinks %}[{{ backlink.display_slug }}={{ backlink.title }}={{ backlink.path }}]{% endfor %}|outgoing={% for link in post.outgoing_links %}[{{ link.display_slug }}={{ link.title }}={{ link.href }}]{% endfor %}|incoming={% for link in post.incoming_links %}[{{ link.display_slug }}={{ link.title }}={{ link.href }}]{% endfor %}"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    assert {:ok, target} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Linked Target",
               content: "target body",
               language: "en",
               template_slug: published_template.slug
             })

    assert {:ok, _translation} =
             BDS.Posts.upsert_post_translation(target.id, "de", %{
               title: "Verlinktes Ziel",
               content: "zieltext"
             })

    assert {:ok, target} = BDS.Posts.publish_post(target.id)

    assert {:ok, source} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Linking Source",
               content: "See [Target Link](#{canonical_post_href(target)})",
               language: "en",
               template_slug: published_template.slug
             })

    assert {:ok, source} = BDS.Posts.publish_post(source.id)

    assert {:ok, rendered_target} =
             Rendering.render_post_page(project.id, published_template.slug, %{
               id: target.id,
               title: target.title,
               content: target.content || "",
               slug: target.slug,
               language: "en",
               template_slug: published_template.slug
             })

    assert rendered_target =~ "alts=[en=#{canonical_post_href(target)}]"
    assert rendered_target =~ "[de=/de#{canonical_post_href(target)}]"

    assert rendered_target =~
             "backlinks=[linking-source=Linking Source=#{canonical_post_href(source)}]"

    assert rendered_target =~
             "incoming=[linking-source=Linking Source=#{canonical_post_href(source)}]"

    assert {:ok, rendered_source} =
             Rendering.render_post_page(project.id, published_template.slug, %{
               id: source.id,
               title: source.title,
               content: source.content || "",
               slug: source.slug,
               language: "en",
               template_slug: published_template.slug
             })

    assert rendered_source =~
             "outgoing=[linked-target=Linked Target=#{canonical_post_href(target)}]"
  end

  test "render_list_page exposes pagination and render_not_found_page localizes default copy", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, list_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Render List Context",
               kind: :list,
               content:
                 "{{ current_page }}|{{ total_pages }}|{{ total_items }}|{{ items_per_page }}|{{ has_prev_page }}|{{ prev_page_href }}|{{ has_next_page }}|{{ next_page_href }}"
             })

    assert {:ok, not_found_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Render Not Found Context",
               kind: :not_found,
               content: "{{ not_found_message }}|{{ not_found_back_label }}"
             })

    assert {:ok, published_list_template} = BDS.Templates.publish_template(list_template.id)

    assert {:ok, _published_not_found_template} =
             BDS.Templates.publish_template(not_found_template.id)

    BDS.Repo.update_all(
      from(template in BDS.Templates.Template,
        where:
          template.project_id == ^project.id and template.kind == :list and
            template.id != ^published_list_template.id
      ),
      set: [enabled: false]
    )

    BDS.Repo.update_all(
      from(template in BDS.Templates.Template,
        where:
          template.project_id == ^project.id and template.kind == :not_found and
            template.slug != ^not_found_template.slug
      ),
      set: [enabled: false]
    )

    assert {:ok, rendered_list} =
             Rendering.render_list_page(project.id, %{
               language: "en",
               page_title: "Archive",
               posts: [],
               archive_context: %{kind: "tag", name: "elixir"},
               pagination: %{
                 current_page: 2,
                 total_pages: 5,
                 total_items: 12,
                 items_per_page: 3,
                 has_prev_page: true,
                 prev_page_href: "/page/1/",
                 has_next_page: true,
                 next_page_href: "/page/3/"
               }
             })

    assert rendered_list == "2|5|12|3|true|/page/1/|true|/page/3/"

    assert {:ok, rendered_not_found} =
             Rendering.render_not_found_page(project.id, %{language: "de"})

    assert rendered_not_found ==
             "Die angeforderte Vorschauseite konnte nicht gefunden werden.|Zurück zur Vorschau-Startseite"

    assert published_list_template.kind == :list
  end

  test "render_list_page groups posts into day blocks and exposes archive range fields", %{
    project: project
  } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, list_template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Render Day Blocks",
               kind: :list,
               content:
                 "range={{ min_date }}-{{ max_date }}|heading={{ show_archive_range_heading }}|blocks={% for block in day_blocks %}[{{ block.date_label }}:{{ block.posts.size }}:{{ block.show_date_marker }}]{% endfor %}|archive={{ archive_context.kind }}:{{ archive_context.year }}:{{ archive_context.month }}"
             })

    assert {:ok, published_list_template} = BDS.Templates.publish_template(list_template.id)

    BDS.Repo.update_all(
      from(template in BDS.Templates.Template,
        where:
          template.project_id == ^project.id and template.kind == :list and
            template.id != ^published_list_template.id
      ),
      set: [enabled: false]
    )

    first_day = 1_711_843_200
    second_day = first_day + 86_400

    posts = [
      %{
        id: "first",
        slug: "first",
        title: "First",
        excerpt: "one",
        language: "en",
        created_at: first_day,
        updated_at: first_day,
        published_at: first_day,
        tags: [],
        categories: [],
        href: "/2024/03/31/first/"
      },
      %{
        id: "second",
        slug: "second",
        title: "Second",
        excerpt: "two",
        language: "en",
        created_at: second_day,
        updated_at: second_day,
        published_at: second_day,
        tags: [],
        categories: [],
        href: "/2024/04/01/second/"
      }
    ]

    assert {:ok, rendered} =
             Rendering.render_list_page(project.id, %{
               language: "en",
               page_title: "Archive",
               posts: posts,
               archive_context: %{kind: "date", year: 2024, month: 4},
               pagination: %{
                 current_page: 1,
                 total_pages: 1,
                 total_items: 2,
                 items_per_page: 10,
                 has_prev_page: false,
                 prev_page_href: nil,
                 has_next_page: false,
                 next_page_href: nil
               }
             })

    assert rendered =~ "heading=true"
    assert rendered =~ "blocks=[2024-03-31:1:true][2024-04-01:1:true]"
    assert rendered =~ "archive=date:2024:4"
    assert rendered =~ "range=1711843200-1711929600"
  end

  test "render_post_page falls back to bundled starter template when the published default template file is missing",
       %{
         project: project
       } do
    assert {:ok, _metadata} =
             BDS.Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en"]
             })

    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Broken Default Post Template",
               kind: :post,
               content: "this custom template should not be used"
             })

    assert {:ok, published_template} = BDS.Templates.publish_template(template.id)

    BDS.Repo.update_all(
      from(template in BDS.Templates.Template,
        where: template.id == ^published_template.id
      ),
      set: [slug: "single-post", file_path: "templates/single-post.liquid", content: nil]
    )

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Fallback Body",
               content: "**Rendered** body",
               language: "en"
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, rendered} =
             Rendering.render_post_page(project.id, nil, %{
               id: published_post.id,
               title: published_post.title,
               content: BDS.Posts.editor_body(published_post),
               slug: published_post.slug,
               language: published_post.language,
               excerpt: published_post.excerpt,
               template_slug: published_post.template_slug
             })

    assert rendered =~ ~s(data-template="single-post")
    assert rendered =~ ~s(<strong>Rendered</strong> body)
    refute rendered =~ "this custom template should not be used"
  end

  defp canonical_post_href(post) do
    datetime = DateTime.from_unix!(post.created_at, :millisecond)

    "/#{datetime.year}/#{String.pad_leading(Integer.to_string(datetime.month), 2, "0")}/#{String.pad_leading(Integer.to_string(datetime.day), 2, "0")}/#{post.slug}/"
  end
end
