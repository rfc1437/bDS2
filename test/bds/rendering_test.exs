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
end
