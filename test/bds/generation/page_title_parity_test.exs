defmodule BDS.Generation.PageTitleParityTest do
  use ExUnit.Case, async: false

  alias BDS.Generation

  @blog_description "My Wonderful Blog"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-page-title-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "PageTitleBlog", data_path: temp_dir})

    {:ok, _} =
      BDS.Metadata.update_project_metadata(project.id, %{
        main_language: "en",
        description: @blog_description
      })

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Hello Post",
        content: "Body of the hello post",
        categories: ["article"],
        tags: ["news"],
        language: "en"
      })

    {:ok, _} = BDS.Posts.publish_post(post.id)

    %{project: project, temp_dir: temp_dir}
  end

  defp read_html(temp_dir, segments) do
    path = Path.join([temp_dir, "html"] ++ segments ++ ["index.html"])
    assert File.exists?(path), "expected page at #{Enum.join(segments, "/")}"
    File.read!(path)
  end

  defp document_title(html) do
    case Regex.run(~r{<title>(.*?)</title>}s, html) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  test "home page document title is the blog title", %{project: project, temp_dir: temp_dir} do
    {:ok, _} = Generation.render_site_section(project.id, :core)

    home_html = read_html(temp_dir, [])
    assert document_title(home_html) == @blog_description
  end

  test "archive document titles are the blog title while headings show the label", %{
    project: project,
    temp_dir: temp_dir
  } do
    {:ok, _} = Generation.render_site_section(project.id, :category)
    {:ok, _} = Generation.render_site_section(project.id, :tag)

    category_html = read_html(temp_dir, ["category", "article"])
    tag_html = read_html(temp_dir, ["tag", "news"])

    assert document_title(category_html) == @blog_description
    assert document_title(tag_html) == @blog_description

    assert category_html =~ ~s(<h1 class="archive-heading">article</h1>)
    assert tag_html =~ ~s(<h1 class="archive-heading">news</h1>)
  end

  test "category archive heading uses the configured descriptive title", %{
    project: project,
    temp_dir: temp_dir
  } do
    {:ok, _} =
      BDS.Metadata.update_category_settings(project.id, "article", %{
        "render_in_lists" => true,
        "show_title" => true,
        "title" => "Long Form Articles"
      })

    {:ok, _} = Generation.render_site_section(project.id, :category)

    category_html = read_html(temp_dir, ["category", "article"])

    assert category_html =~ ~s(<h1 class="archive-heading">Long Form Articles</h1>)
    refute category_html =~ ~s(<h1 class="archive-heading">article</h1>)
    assert document_title(category_html) == @blog_description
  end
end
