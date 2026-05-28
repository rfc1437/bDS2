defmodule BDS.TemplateLookupPriorityTest do
  use ExUnit.Case, async: false

  alias BDS.Rendering.TemplateSelection

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-tlp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "TLP Test", data_path: temp_dir})

    {:ok, _metadata} =
      BDS.Metadata.update_project_metadata(project.id, %{
        main_language: "en",
        blog_languages: ["en"]
      })

    %{project: project}
  end

  defp create_published_template(project_id, slug, content) do
    {:ok, template} =
      BDS.Templates.create_template(%{
        project_id: project_id,
        title: "Template #{slug}",
        kind: :post,
        content: content
      })

    if template.slug != slug do
      BDS.Repo.update!(Ecto.Changeset.change(template, slug: slug))
    end

    {:ok, published} = BDS.Templates.publish_template(template.id)
    published
  end

  defp create_tag(project_id, name, post_template_slug) do
    {:ok, tag} =
      BDS.Tags.create_tag(%{
        project_id: project_id,
        name: name,
        post_template_slug: post_template_slug
      })

    tag
  end

  describe "resolve_post_template_slug/3" do
    test "level 1: returns post's own template_slug when set", %{project: project} do
      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          ["some-tag"],
          ["article"]
        )

      assert result == nil
    end

    test "level 2: falls back to tag's post_template_slug", %{project: project} do
      _tag = create_tag(project.id, "photo", "photo-layout")

      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          ["photo"],
          []
        )

      assert result == "photo-layout"
    end

    test "level 2: uses first matching tag with a template slug", %{project: project} do
      _tag1 = create_tag(project.id, "news", nil)
      _tag2 = create_tag(project.id, "gallery", "gallery-layout")

      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          ["news", "gallery"],
          []
        )

      assert result == "gallery-layout"
    end

    test "level 3: falls back to category's post_template_slug", %{project: project} do
      {:ok, _} = BDS.Metadata.add_category(project.id, "review")

      {:ok, _} =
        BDS.Metadata.update_category_settings(project.id, "review", %{
          "post_template_slug" => "review-layout"
        })

      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          [],
          ["review"]
        )

      assert result == "review-layout"
    end

    test "level 2 takes priority over level 3", %{project: project} do
      _tag = create_tag(project.id, "featured", "featured-layout")
      {:ok, _} = BDS.Metadata.add_category(project.id, "review")

      {:ok, _} =
        BDS.Metadata.update_category_settings(project.id, "review", %{
          "post_template_slug" => "review-layout"
        })

      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          ["featured"],
          ["review"]
        )

      assert result == "featured-layout"
    end

    test "level 4: returns nil when no tag or category has a template", %{project: project} do
      _tag = create_tag(project.id, "plain", nil)

      result =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          ["plain"],
          ["article"]
        )

      assert result == nil
    end
  end

  describe "end-to-end template lookup with rendering" do
    test "post renders with tag-specific template when no post template set", %{
      project: project
    } do
      template =
        create_published_template(project.id, "photo-layout", "<h1>PHOTO: {{ page.title }}</h1>")

      _tag = create_tag(project.id, "photo", template.slug)

      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "My Photo Post",
          content: "photo content",
          language: "en",
          tags: ["photo"]
        })

      resolved_slug =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          post.tags,
          post.categories
        )

      assert resolved_slug == "photo-layout"

      {:ok, rendered} =
        TemplateSelection.load_template_source(project.id, :post, resolved_slug)

      assert rendered =~ "PHOTO:"
    end

    test "post renders with category-specific template when no post or tag template", %{
      project: project
    } do
      template =
        create_published_template(
          project.id,
          "review-layout",
          "<h1>REVIEW: {{ page.title }}</h1>"
        )

      {:ok, _} = BDS.Metadata.add_category(project.id, "review")

      {:ok, _} =
        BDS.Metadata.update_category_settings(project.id, "review", %{
          "post_template_slug" => template.slug
        })

      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "My Review",
          content: "review content",
          language: "en",
          categories: ["review"]
        })

      resolved_slug =
        TemplateSelection.resolve_post_template_slug(
          project.id,
          post.tags,
          post.categories
        )

      assert resolved_slug == "review-layout"

      {:ok, rendered} =
        TemplateSelection.load_template_source(project.id, :post, resolved_slug)

      assert rendered =~ "REVIEW:"
    end
  end
end
