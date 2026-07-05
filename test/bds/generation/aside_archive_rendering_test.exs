defmodule BDS.Generation.AsideArchiveRenderingTest do
  use ExUnit.Case, async: false

  alias BDS.Generation

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-aside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "AsideArchives", data_path: temp_dir})
    {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{main_language: "en"})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Aside Title Marker",
        content: "ASIDE BODY MARKER text of the aside",
        categories: ["aside"],
        tags: ["asides-tag"],
        language: "en"
      })

    {:ok, _} = BDS.Posts.publish_post(post.id)

    %{project: project, temp_dir: temp_dir}
  end

  defp read_archive(temp_dir, segments) do
    path = Path.join([temp_dir, "html"] ++ segments ++ ["index.html"])
    assert File.exists?(path), "expected archive page at #{Enum.join(segments, "/")}"
    File.read!(path)
  end

  test "aside bodies render in category, tag, and date archives alike", %{
    project: project,
    temp_dir: temp_dir
  } do
    {:ok, _} = Generation.render_site_section(project.id, :category)
    {:ok, _} = Generation.render_site_section(project.id, :tag)
    {:ok, _} = Generation.render_site_section(project.id, :date)

    year = Integer.to_string(DateTime.utc_now().year)
    date_html = read_archive(temp_dir, [year])
    category_html = read_archive(temp_dir, ["category", "aside"])
    tag_html = read_archive(temp_dir, ["tag", "asides-tag"])

    assert date_html =~ "ASIDE BODY MARKER"
    assert category_html =~ "ASIDE BODY MARKER"
    assert tag_html =~ "ASIDE BODY MARKER"
  end
end
