defmodule BDS.TemplatesTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags.Tag

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-templates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Templates", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "create_template creates a draft template with slug deduplication", %{project: project} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "<article>{{ content }}</article>"
             })

    assert template.slug == "article-view"
    assert template.status == :draft
    assert template.enabled == true
    assert template.version == 1
    assert template.file_path == "templates/article-view.liquid"
    assert template.content == "<article>{{ content }}</article>"

    assert {:ok, duplicate} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "x"
             })

    assert duplicate.slug == "article-view-2"
  end

  test "create_template writes template file to disk", %{project: project, temp_dir: temp_dir} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "My Layout",
               kind: :post,
               content: "<main>{{ content }}</main>"
             })

    assert template.file_path == "templates/my-layout.liquid"

    full_path = Path.join(temp_dir, template.file_path)
    assert File.exists?(full_path)

    contents = File.read!(full_path)
    assert contents =~ "---\nid: #{template.id}\n"
    assert contents =~ "slug: my-layout\n"
    assert contents =~ "title: My Layout\n"
    assert contents =~ "kind: post\n"
    assert contents =~ "\n---\n<main>{{ content }}</main>\n"
  end

  test "publish_template writes a liquid file with frontmatter and clears draft content", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Landing Page",
               kind: :list,
               content: "<section>{{ page_title }}</section>"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)

    assert published.status == :published
    assert published.content == nil
    assert published.file_path == "templates/landing-page.liquid"

    full_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(full_path)

    contents = File.read!(full_path)
    assert contents =~ "---\nid: #{published.id}\n"
    assert contents =~ "projectId: #{project.id}\n"
    assert contents =~ "slug: landing-page\n"
    assert contents =~ "title: Landing Page\n"
    assert contents =~ "kind: list\n"
    assert contents =~ "enabled: true\n"
    assert contents =~ "version: 1\n"
    assert contents =~ ~r/createdAt: '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'\n/
    assert contents =~ ~r/updatedAt: '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'\n/
    assert contents =~ "\n---\n<section>{{ page_title }}</section>\n"
    refute File.exists?(full_path <> ".tmp")
  end

  test "update_template bumps version and reopens a published template when content changes", %{
    project: project
  } do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Snippet",
               kind: :partial,
               content: "<span>v1</span>"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)
    assert published.status == :published

    assert {:ok, updated} =
             BDS.Templates.update_template(template.id, %{
               content: "<span>v2</span>",
               enabled: false
             })

    assert updated.version == 2
    assert updated.status == :draft
    assert updated.enabled == false
    assert updated.file_path == "templates/snippet.liquid"
    assert updated.content == "<span>v2</span>"
    assert updated.updated_at >= published.updated_at
  end

  test "delete_template refuses referenced templates unless forced, then clears references and deletes the file",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "<article>{{ content }}</article>"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Uses Template",
               content: "Body",
               template_slug: published.slug
             })

    assert {:ok, _published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, _tag} =
             BDS.Tags.create_tag(%{
               project_id: project.id,
               name: "Feature",
               post_template_slug: published.slug
             })

    assert {:error, {:has_references, %{posts: 1, tags: 1}}} =
             BDS.Templates.delete_template(published.id)

    assert {:ok, :deleted} = BDS.Templates.delete_template(published.id, force: true)

    reloaded_post = Repo.get(Post, hd(Repo.all(from p in Post, select: p.id)))
    reloaded_tag = Repo.get(Tag, hd(Repo.all(from t in Tag, select: t.id)))

    assert reloaded_post.template_slug == nil
    assert reloaded_tag.post_template_slug == nil

    refute File.exists?(Path.join(temp_dir, published.file_path))

    post_path = Path.join(temp_dir, reloaded_post.file_path)
    post_contents = File.read!(post_path)
    refute post_contents =~ "template_slug:"
    assert post_contents =~ "\n---\nBody\n"

    tags_path = Path.join([temp_dir, "meta", "tags.json"])
    assert [%{"name" => "Feature"}] = Jason.decode!(File.read!(tags_path))
  end

  test "update_template cascades slug changes to posts and tags and renames the published file",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "<article>{{ content }}</article>"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Uses Template",
               content: "Body",
               template_slug: published.slug
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, _tag} =
             BDS.Tags.create_tag(%{
               project_id: project.id,
               name: "Feature",
               post_template_slug: published.slug
             })

    old_template_path = Path.join(temp_dir, published.file_path)
    assert File.exists?(old_template_path)

    assert {:ok, updated} = BDS.Templates.update_template(published.id, %{slug: "feature-view"})

    assert updated.slug == "feature-view"
    assert updated.file_path == "templates/feature-view.liquid"

    reloaded_post = Repo.get!(Post, published_post.id)
    assert reloaded_post.template_slug == "feature-view"

    reloaded_tag = Repo.get_by!(Tag, project_id: project.id, name: "Feature")
    assert reloaded_tag.post_template_slug == "feature-view"

    refute File.exists?(old_template_path)
    new_template_path = Path.join(temp_dir, updated.file_path)
    assert File.exists?(new_template_path)

    template_contents = File.read!(new_template_path)
    assert template_contents =~ "slug: feature-view\n"
    assert template_contents =~ "\n---\n<article>{{ content }}</article>\n"

    post_contents = File.read!(Path.join(temp_dir, reloaded_post.file_path))
    assert post_contents =~ "templateSlug: feature-view\n"
    assert post_contents =~ "\n---\nBody\n"

    tags_path = Path.join([temp_dir, "meta", "tags.json"])

    assert [%{"name" => "Feature", "postTemplateSlug" => "feature-view"}] =
             Jason.decode!(File.read!(tags_path))
  end

  test "update_template keeps committed database changes when renaming the published file fails",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "<article>{{ content }}</article>"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Uses Template",
               content: "Body",
               template_slug: published.slug
             })

    assert {:ok, published_post} = BDS.Posts.publish_post(post.id)

    assert {:ok, _tag} =
             BDS.Tags.create_tag(%{
               project_id: project.id,
               name: "Feature",
               post_template_slug: published.slug
             })

    blocked_path = Path.join([temp_dir, "templates", "feature-view.liquid.tmp"])
    File.mkdir_p!(blocked_path)

    assert {:error, _reason} =
             BDS.Templates.update_template(published.id, %{slug: "feature-view"})

    reloaded_template = Repo.get!(BDS.Templates.Template, published.id)
    assert reloaded_template.slug == "feature-view"
    assert reloaded_template.file_path == "templates/feature-view.liquid"

    reloaded_post = Repo.get!(Post, published_post.id)
    assert reloaded_post.template_slug == "feature-view"

    reloaded_tag = Repo.get_by!(Tag, project_id: project.id, name: "Feature")
    assert reloaded_tag.post_template_slug == "feature-view"
  end

  test "publish_template rejects invalid Liquid syntax", %{project: project} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Bad Template",
               kind: :post,
               content: "{% for item in items %}unclosed"
             })

    assert {:error, {:invalid_liquid, _reason}} = BDS.Templates.publish_template(template.id)

    reloaded = Repo.get!(BDS.Templates.Template, template.id)
    assert reloaded.status == :draft
    assert reloaded.content == "{% for item in items %}unclosed"
  end

  test "publish_template allows valid Liquid syntax", %{project: project} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Good Template",
               kind: :post,
               content: "{% for item in items %}{{ item }}{% endfor %}"
             })

    assert {:ok, published} = BDS.Templates.publish_template(template.id)
    assert published.status == :published
  end

  # LiquidTagSubset invariant (template.allium): only {% if %}, {% for %},
  # {% assign %}, {% render %} (plus {{ }} output) are supported. Any tag
  # outside that subset must be rejected at publish time.
  for tag <- ["unless", "case", "capture", "tablerow", "cycle", "increment"] do
    @tag_name tag
    test "publish_template rejects unsupported Liquid tag #{tag}", %{
      project: project
    } do
      tag = @tag_name

      assert {:ok, template} =
               BDS.Templates.create_template(%{
                 project_id: project.id,
                 title: "Tag #{tag}",
                 kind: :post,
                 content: "{% #{tag} foo %}bar{% end#{tag} %}"
               })

      assert {:error, {:invalid_liquid, _reason}} = BDS.Templates.publish_template(template.id)

      reloaded = Repo.get!(BDS.Templates.Template, template.id)
      assert reloaded.status == :draft
    end
  end

  # LiquidFilterSubset invariant (template.allium): only escape, url_encode,
  # default, append (standard) and i18n, markdown, slugify (custom) are allowed.
  # Any other filter must be rejected at publish time, even though Liquex would
  # otherwise apply it as a built-in standard filter.
  for filter <- ["upcase", "downcase", "date", "truncate", "split", "reverse"] do
    @filter_name filter
    test "publish_template rejects unsupported Liquid filter #{filter}", %{
      project: project
    } do
      filter = @filter_name

      assert {:ok, template} =
               BDS.Templates.create_template(%{
                 project_id: project.id,
                 title: "Filter #{filter}",
                 kind: :post,
                 content: "{{ title | #{filter} }}"
               })

      assert {:error, {:invalid_liquid, reason}} =
               BDS.Templates.publish_template(template.id)

      assert reason =~ "unsupported filter: #{filter}"

      reloaded = Repo.get!(BDS.Templates.Template, template.id)
      assert reloaded.status == :draft
    end
  end

  for filter <- ["escape", "url_encode", "slugify"] do
    @filter_name filter
    test "publish_template allows supported Liquid filter #{filter}", %{
      project: project
    } do
      filter = @filter_name

      assert {:ok, template} =
               BDS.Templates.create_template(%{
                 project_id: project.id,
                 title: "Filter #{filter}",
                 kind: :post,
                 content: "{{ title | #{filter} }}"
               })

      assert {:ok, published} = BDS.Templates.publish_template(template.id)
      assert published.status == :published
    end
  end

  # LiquidOperatorSubset invariant (template.allium): only == and > comparison
  # operators (plus the and/or logical operators and bare-variable truthiness)
  # are allowed. Any other comparison operator must be rejected at publish time,
  # even though Liquex would otherwise evaluate it.
  for op <- ["!=", "<", ">=", "<=", "contains"] do
    @op_name op
    test "publish_template rejects unsupported Liquid operator #{op}", %{
      project: project
    } do
      op = @op_name

      assert {:ok, template} =
               BDS.Templates.create_template(%{
                 project_id: project.id,
                 title: "Operator #{op}",
                 kind: :post,
                 content: "{% if title #{op} other %}yes{% endif %}"
               })

      assert {:error, {:invalid_liquid, reason}} =
               BDS.Templates.publish_template(template.id)

      assert reason =~ "unsupported operator: #{op}"

      reloaded = Repo.get!(BDS.Templates.Template, template.id)
      assert reloaded.status == :draft
    end
  end

  for content <- [
        "{% if title == other %}yes{% endif %}",
        "{% if total > 0 %}yes{% endif %}",
        "{% if published %}yes{% endif %}",
        "{% if a == b and c > d %}yes{% endif %}",
        "{% if a == b or c == d %}yes{% endif %}"
      ] do
    @op_content content
    test "publish_template allows supported operators in #{content}", %{project: project} do
      content = @op_content

      assert {:ok, template} =
               BDS.Templates.create_template(%{
                 project_id: project.id,
                 title: "Allowed #{content}",
                 kind: :post,
                 content: content
               })

      assert {:ok, published} = BDS.Templates.publish_template(template.id)
      assert published.status == :published
    end
  end

  test "rebuild_templates_from_files recreates published templates from disk", %{
    project: project,
    temp_dir: temp_dir
  } do
    template_dir = Path.join(temp_dir, "templates")
    File.mkdir_p!(template_dir)

    file_path = Path.join(template_dir, "recovered-view.liquid")

    File.write!(
      file_path,
      [
        "---",
        "id: template-from-file",
        "projectId: #{project.id}",
        "slug: recovered-view",
        "title: Recovered View",
        "kind: list",
        "enabled: true",
        "version: 3",
        "createdAt: 1970-01-01T00:00:00.101Z",
        "updatedAt: 1970-01-01T00:00:00.202Z",
        "---",
        "<section>Recovered</section>",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, templates} = BDS.Templates.rebuild_templates_from_files(project.id)
    assert length(templates) == 1

    template = Repo.get!(BDS.Templates.Template, "template-from-file")
    assert template.id == "template-from-file"
    assert template.slug == "recovered-view"
    assert template.title == "Recovered View"
    assert template.kind == :list
    assert template.enabled == true
    assert template.version == 3
    assert template.status == :published
    assert template.file_path == "templates/recovered-view.liquid"
    assert template.content == nil
    assert template.created_at == 101
    assert template.updated_at == 202
  end

  test "rebuild_templates_from_files removes stale published default templates when no local template files exist",
       %{
         project: project
       } do
    now = BDS.Persistence.now_ms()

    stale_template =
      %BDS.Templates.Template{}
      |> BDS.Templates.Template.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        slug: "single-post",
        title: "Single Post",
        kind: :post,
        enabled: true,
        version: 1,
        file_path: "templates/single-post.liquid",
        status: :published,
        content: nil,
        created_at: now,
        updated_at: now
      })
      |> Repo.insert!()

    assert {:ok, templates} = BDS.Templates.rebuild_templates_from_files(project.id)
    assert templates == []
    assert Repo.get(BDS.Templates.Template, stale_template.id) == nil
  end
end
