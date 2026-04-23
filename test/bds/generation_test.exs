defmodule BDS.GenerationTest do
  use ExUnit.Case, async: false

  alias BDS.Metadata
  alias BDS.Posts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-generation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Generation", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "write_generated_file writes under html output and skips unchanged content by hash", %{project: project, temp_dir: temp_dir} do
    assert {:ok, first_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")
    assert first_write.written? == true

    output_path = Path.join([temp_dir, "html", "index.html"])
    assert File.read!(output_path) == "<html>hello</html>"

    assert {:ok, [tracked_file]} = BDS.Generation.list_generated_files(project.id)
    assert tracked_file.relative_path == "index.html"
    assert tracked_file.content_hash == first_write.content_hash

    assert {:ok, second_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")
    assert second_write.written? == false
    assert second_write.content_hash == first_write.content_hash

    assert {:ok, third_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>updated</html>")
    assert third_write.written? == true
    assert third_write.content_hash != first_write.content_hash
    assert File.read!(output_path) == "<html>updated</html>"
  end

  test "delete_generated_file removes tracked output and forgets its hash", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _write} = BDS.Generation.write_generated_file(project.id, "tag/elixir/index.html", "<html>tag</html>")

    output_path = Path.join([temp_dir, "html", "tag", "elixir", "index.html"])
    assert File.exists?(output_path)

    assert :ok = BDS.Generation.delete_generated_file(project.id, "tag/elixir/index.html")
    refute File.exists?(output_path)

    assert {:ok, files} = BDS.Generation.list_generated_files(project.id)
    assert files == []
  end

  test "plan_generation derives generation settings from project metadata and core generation writes tracked files", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"],
               max_posts_per_page: 25,
               pico_theme: "amber"
             })

    assert {:ok, plan} = BDS.Generation.plan_generation(project.id, [:core])
    assert plan.project_id == project.id
    assert plan.base_url == "https://example.com/blog"
    assert plan.language == "en"
    assert plan.blog_languages == ["en", "de"]
    assert plan.max_posts_per_page == 25
    assert plan.pico_theme == "amber"
    assert plan.sections == [:core]
    assert plan.generated_files == []

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:core])
    assert result.sections == [:core]

    expected_paths = [
      "index.html",
      "sitemap.xml",
      "feed.xml",
      "atom.xml",
      "calendar.json",
      "de/index.html",
      "de/feed.xml",
      "de/atom.xml"
    ]

    assert Enum.sort(Enum.map(result.generated_files, & &1.relative_path)) == Enum.sort(expected_paths)

    for relative_path <- expected_paths do
      assert File.exists?(Path.join([temp_dir, "html", relative_path]))
    end

    assert File.read!(Path.join([temp_dir, "html", "sitemap.xml"])) =~ "https://example.com/blog/"
  end

  test "single generation writes canonical post pages and language-prefixed translation pages", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               public_url: "https://example.com/blog",
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "My Post",
               content: "Hello generated world",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Mein Beitrag",
               content: "Hallo generierte Welt"
             })

    assert {:ok, published_post} = Posts.publish_post(post.id)

    assert {:ok, result} = BDS.Generation.generate_site(project.id, [:single])

    post_path = BDS.Generation.post_output_path(published_post)
    translation_path = BDS.Generation.post_output_path(published_post, "de")

    assert Enum.map(result.generated_files, & &1.relative_path) |> Enum.sort() == Enum.sort([post_path, translation_path])

    assert File.read!(Path.join([temp_dir, "html", post_path])) =~ "Hello generated world"
    assert File.read!(Path.join([temp_dir, "html", translation_path])) =~ "Hallo generierte Welt"
    assert File.read!(Path.join([temp_dir, "html", post_path])) =~ ~s(data-pagefind-body)
  end
end
