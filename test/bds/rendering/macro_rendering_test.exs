defmodule BDS.Rendering.MacroRenderingTest do
  @moduledoc """
  End-to-end coverage for built-in macros through the *real* render pipeline
  (`RenderContext.build/1`). These guard the regression where photo archive and
  tag cloud rendered empty because the project id was never threaded into the
  macro context, and where galleries rendered empty on list pages because the
  post id was dropped.
  """
  use ExUnit.Case, async: false

  alias BDS.Media
  alias BDS.Rendering
  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.RenderContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir = Path.join(System.tmp_dir!(), "bds-macros-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "MacroBlog", data_path: temp_dir})
    {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{main_language: "en"})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Macro Post",
        content: "seed",
        language: "en",
        tags: ["elixir", "phoenix"]
      })

    source = Path.join(temp_dir, "macro_image.jpg")
    File.write!(source, "fake jpeg")
    {:ok, media} = Media.import_media(%{project_id: project.id, source_path: source})
    {:ok, _} = Media.update_media(media.id, %{title: "Macro Image", alt: "Macro Alt"})
    {:ok, _} = Media.link_media_to_post(media.id, post.id)

    {:ok, _} = BDS.Posts.publish_post(post.id)

    %{project: project, post: post}
  end

  test "photo archive and tag cloud resolve project data on single-post render", %{
    project: project,
    post: post
  } do
    ctx = RenderContext.build(project.id)

    rendered =
      PostRendering.cached_post_content(
        ctx,
        "[[photo_archive]]\n\n[[tag_cloud]]",
        "en",
        post.id
      )

    assert rendered =~ "photo-archive-item"
    refute rendered =~ "photo-archive-empty"

    assert rendered =~ "data-tag-cloud-words"
    refute rendered =~ "tag-cloud-empty"

    # The JSON is embedded in a double-quoted HTML attribute, so it must be
    # HTML-escaped or the client-side JSON.parse silently fails (empty cloud).
    assert rendered =~ "&quot;"

    words = extract_tag_cloud_words(rendered)
    texts = Enum.map(words, &Map.get(&1, "text"))
    assert "elixir" in texts
    assert "phoenix" in texts

    # Matches the old app's word shape so the d3 runtime can size/link tags.
    for word <- words do
      assert is_integer(word["count"])
      assert word["size"] >= 14 and word["size"] <= 56
      assert String.starts_with?(word["url"], "/tag/")
    end
  end

  defp extract_tag_cloud_words(html) do
    [_, raw] = Regex.run(~r/data-tag-cloud-words="([^"]*)"/, html)

    raw
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&#39;", "'")
    |> Jason.decode!()
  end

  test "tag cloud orientation aliases normalize like the old app", %{
    project: project,
    post: post
  } do
    ctx = RenderContext.build(project.id)

    render = fn source -> PostRendering.cached_post_content(ctx, source, "en", post.id) end

    assert render.("[[tag_cloud orientation=diagonal]]") =~ ~s(data-orientation="mixed-diagonal")
    assert render.("[[tag_cloud orientation=diag]]") =~ ~s(data-orientation="mixed-diagonal")

    assert render.("[[tag_cloud orientation=mixed-diagonal]]") =~
             ~s(data-orientation="mixed-diagonal")

    assert render.("[[tag_cloud orientation=hv]]") =~ ~s(data-orientation="mixed-hv")
    assert render.("[[tag_cloud orientation=mixed-hv]]") =~ ~s(data-orientation="mixed-hv")
    assert render.("[[tag_cloud]]") =~ ~s(data-orientation="horizontal")
    assert render.("[[tag_cloud orientation=bogus]]") =~ ~s(data-orientation="horizontal")
  end

  test "tag cloud clamps out-of-range width/height to defaults", %{project: project, post: post} do
    ctx = RenderContext.build(project.id)

    rendered =
      PostRendering.cached_post_content(ctx, "[[tag_cloud width=99999 height=1]]", "en", post.id)

    assert rendered =~ ~s(data-width="900")
    assert rendered =~ ~s(data-height="420")
  end

  test "gallery resolves linked media on single-post render", %{project: project, post: post} do
    ctx = RenderContext.build(project.id)

    rendered = PostRendering.cached_post_content(ctx, "[[gallery]]", "en", post.id)

    assert rendered =~ "gallery-item"
    assert rendered =~ ~s(src="/media/)
    assert rendered =~ "Macro Image"
    refute rendered =~ "gallery-empty"
  end

  test "gallery resolves linked media on list-page render", %{project: project, post: post} do
    posts = [
      %{
        id: post.id,
        slug: post.slug,
        title: post.title,
        content: "[[gallery]]",
        language: "en",
        created_at: post.created_at,
        updated_at: post.updated_at,
        published_at: post.published_at,
        tags: post.tags,
        categories: post.categories,
        href: "/2024/01/01/macro-post/"
      }
    ]

    assert {:ok, rendered} =
             Rendering.render_list_page(project.id, %{
               language: "en",
               page_title: "Archive",
               posts: posts,
               archive_context: %{kind: "core"},
               pagination: %{
                 current_page: 1,
                 total_pages: 1,
                 total_items: 1,
                 items_per_page: 10,
                 has_prev_page: false,
                 prev_page_href: nil,
                 has_next_page: false,
                 next_page_href: nil
               }
             })

    assert rendered =~ "gallery-item"
    assert rendered =~ ~s(src="/media/)
    refute rendered =~ "gallery-empty"
  end
end
