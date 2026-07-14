defmodule BDS.GalleryPipelineTest do
  use ExUnit.Case, async: false

  alias BDS.{Repo, Media}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-gallery-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Gallery Test", data_path: temp_dir})
    {:ok, _project} = BDS.Projects.set_active_project(project.id)

    {:ok, _metadata} =
      BDS.Metadata.update_project_metadata(project.id, %{
        blog_languages: ["de", "fr"],
        main_language: "en"
      })

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Gallery Post",
        content: "Content"
      })

    %{project: project, post: post, temp_dir: temp_dir}
  end

  describe "GalleryImport.start/6 concurrency" do
    test "processes all paths with a sliding window", %{project: project, post: post} do
      parent = self()
      concurrency = 2

      paths =
        Enum.map(1..5, fn i ->
          path = Path.join(project.data_path, "image_#{i}.txt")
          File.write!(path, "content #{i}")
          path
        end)

      ref = make_ref()
      send(parent, {:test_gallery_start, ref, paths, project.id, post.id, concurrency})
    end
  end

  # ── gallery_count with [[gallery]] ─────────────────────────────────────────

  describe "gallery_count" do
    test "counts [[gallery]] macro as gallery content" do
      form = %{"content" => "Some text\n\n[[gallery]]\n\nMore text"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 1
    end

    test "counts inline images as before" do
      form = %{"content" => "![Alt](image.jpg)"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 1
    end

    test "counts both [[gallery]] and inline images" do
      form = %{"content" => "![Alt](image.jpg)\n[[gallery]]"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 1
    end

    test "returns 0 when no gallery marks present" do
      form = %{"content" => "Just plain text"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 0
    end

    test "handles empty content" do
      form = %{}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 0
    end

    test "counts multiple [[gallery]] occurrences" do
      form = %{"content" => "[[gallery]] some text [[gallery]]"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 2
    end

    test "is case insensitive for [[gallery]]" do
      form = %{"content" => "[[Gallery]]"}

      assert BDS.UI.PostEditor.Metadata.gallery_count(form) == 1
    end
  end

  # ── Rendering macro smoke tests ────────────────────────────────────────────

  describe "rendering macros" do
    test "[[gallery]] renders without linked media", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[gallery]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "gallery-empty"
      assert result =~ "macro-gallery"
    end

    test "[[gallery]] renders linked media when present", %{project: project, post: post} do
      source = Path.join(project.data_path, "gallery_test.jpg")
      File.write!(source, "fake jpeg")

      {:ok, media} =
        Media.import_media(%{project_id: project.id, source_path: source})

      {:ok, _updated} =
        Media.update_media(media.id, %{
          title: "Test Image",
          alt: "Alt text",
          caption: "Caption"
        })

      {:ok, _link} = Media.link_media_to_post(media.id, post.id)

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"
      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[gallery]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "macro-gallery"
      assert result =~ "gallery-item"
    end

    test "[[tag_cloud]] renders without tags", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[tag_cloud]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "tag-cloud-empty"
    end

    test "renders GFM tables, strikethrough and autolinks like Earmark did", %{
      project: project,
      post: post
    } do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"
      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      markdown = """
      | A | B |
      |---|---|
      | 1 | 2 |

      ~~gone~~ and visit https://example.com now
      """

      result =
        BDS.Rendering.Filters.render_markdown(
          markdown,
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "<table>"
      assert result =~ "<del>gone</del>"
      assert result =~ ~s(<a href="https://example.com">)
    end

    test "[[photo_archive]] renders without media", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[photo_archive]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "photo-archive-empty"
    end

    test "[[photo_archive year=2024]] renders with date filter", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[photo_archive year=2024]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "photo-archive"
    end

    test "[[youtube id=abc123]] still works", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[youtube id=abc123]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "youtube"
      assert result =~ "abc123"
    end

    test "[[vimeo id=456789]] still works", %{project: project, post: post} do
      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      language = metadata.main_language || "en"

      template_context = BDS.Rendering.TemplateSelection.template_render_context(project.id)

      result =
        BDS.Rendering.Filters.render_markdown(
          "[[vimeo id=456789]]",
          %{},
          %{},
          language,
          template_context,
          post.id
        )

      assert result =~ "vimeo"
      assert result =~ "456789"
    end
  end
end
