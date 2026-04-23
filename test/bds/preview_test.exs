defmodule BDS.PreviewTest do
  use ExUnit.Case, async: false

  alias BDS.Generation
  alias BDS.Metadata
  alias BDS.Posts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Preview", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "start_preview binds localhost and request resolves generated routes, assets, media, and draft previews", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, _} = Generation.write_generated_file(project.id, "index.html", "<html>home</html>")
    assert {:ok, _} = Generation.write_generated_file(project.id, "de/index.html", "<html>startseite</html>")
    assert {:ok, _} = Generation.write_generated_file(project.id, "tag/elixir/index.html", "<html>tag archive</html>")
    assert {:ok, _} = Generation.write_generated_file(project.id, "pagefind/pagefind-ui.js", "console.log('pagefind')")

    media_dir = Path.join([temp_dir, "media", "2026", "04"])
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "image.txt"), "media body")

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Draft Post",
               content: "Draft preview body",
               language: "en"
             })

    assert {:ok, server} = BDS.Preview.start_preview(project.id)
    assert server.host == "127.0.0.1"
    assert server.port == 4123
    assert server.is_running == true

    assert {:ok, %{body: "<html>home</html>", content_type: "text/html"}} = BDS.Preview.request(project.id, "/")
    assert {:ok, %{body: "<html>startseite</html>", content_type: "text/html"}} = BDS.Preview.request(project.id, "/de/")
    assert {:ok, %{body: "<html>tag archive</html>", content_type: "text/html"}} = BDS.Preview.request(project.id, "/tag/elixir")
    assert {:ok, %{body: "console.log('pagefind')", content_type: "application/javascript"}} = BDS.Preview.request(project.id, "/pagefind/pagefind-ui.js")
    assert {:ok, %{body: "media body", content_type: "text/plain"}} = BDS.Preview.request(project.id, "/media/2026/04/image.txt")

    assert {:ok, %{body: draft_html, content_type: "text/html"}} =
             BDS.Preview.preview_draft(project.id, "/draft/draft-post", post.id)

    assert draft_html =~ "Draft preview body"
    assert {:error, :not_found} = BDS.Preview.request(project.id, "/media/../../secret.txt")

    assert :ok = BDS.Preview.stop_preview(project.id)
  end
end
