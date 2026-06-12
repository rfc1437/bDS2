defmodule BDS.BlogmarkTest do
  use ExUnit.Case, async: false

  alias BDS.Blogmark
  alias BDS.Scripts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-blogmark-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Blogmark", data_path: temp_dir})

    %{project: project}
  end

  describe "parse_deep_link/1" do
    test "parses a new-post deep link into a candidate" do
      url =
        "bds2://new-post?title=" <>
          URI.encode_www_form("Hello World") <>
          "&url=" <> URI.encode_www_form("https://example.com/page")

      assert {:ok, candidate} = Blogmark.parse_deep_link(url)
      assert candidate["title"] == "Hello World"
      assert candidate["url"] == "https://example.com/page"
      assert candidate["content"] == nil
      assert candidate["tags"] == []
      assert candidate["categories"] == []
    end

    test "parses optional content, tags and categories" do
      url =
        "bds2://new-post?title=T&url=https://x&content=" <>
          URI.encode_www_form("body text") <>
          "&tags=" <>
          URI.encode_www_form("a, b ,c") <>
          "&categories=" <> URI.encode_www_form("news")

      assert {:ok, candidate} = Blogmark.parse_deep_link(url)
      assert candidate["content"] == "body text"
      assert candidate["tags"] == ["a", "b", "c"]
      assert candidate["categories"] == ["news"]
    end

    test "rejects an unsupported scheme" do
      assert {:error, :unsupported_scheme} =
               Blogmark.parse_deep_link("bds://new-post?title=T")
    end

    test "rejects an unsupported action" do
      assert {:error, :unsupported_action} =
               Blogmark.parse_deep_link("bds2://open-thing?id=1")
    end
  end

  describe "receive_deep_link/3" do
    test "creates a draft post from the deep link", %{project: project} do
      url =
        "bds2://new-post?title=" <>
          URI.encode_www_form("A Bookmarked Page") <>
          "&url=" <> URI.encode_www_form("https://example.com/a")

      assert {:ok, %{post: post, toasts: [], errors: []}} =
               Blogmark.receive_deep_link(project.id, url)

      assert post.title == "A Bookmarked Page"
      assert post.status == :draft
      assert post.project_id == project.id
    end

    test "runs enabled transforms on the candidate before creating the post", %{project: project} do
      {:ok, _script} =
        Scripts.create_script(%{
          project_id: project.id,
          title: "Prefix",
          kind: :transform,
          content: """
          function main(data, ctx)
            data.title = "[" .. ctx.source .. "] " .. data.title
            return { data = data, toasts = { "transformed" } }
          end
          """,
          entrypoint: "main"
        })

      url = "bds2://new-post?title=Page&url=https://x"

      assert {:ok, %{post: post, toasts: toasts}} =
               Blogmark.receive_deep_link(project.id, url)

      assert post.title == "[blogmark] Page"
      assert toasts == ["transformed"]
    end

    test "defaults the category from blogmark_category when none provided", %{project: project} do
      {:ok, _meta} =
        BDS.Metadata.update_project_metadata(project.id, %{blogmark_category: "aside"})

      url = "bds2://new-post?title=Page&url=https://x"

      assert {:ok, %{post: post}} = Blogmark.receive_deep_link(project.id, url)
      assert post.categories == ["aside"]
    end

    test "keeps explicit categories over the blogmark default", %{project: project} do
      {:ok, _meta} =
        BDS.Metadata.update_project_metadata(project.id, %{blogmark_category: "aside"})

      url = "bds2://new-post?title=Page&url=https://x&categories=article"

      assert {:ok, %{post: post}} = Blogmark.receive_deep_link(project.id, url)
      assert post.categories == ["article"]
    end

    test "returns an error for an invalid deep link", %{project: project} do
      assert {:error, :unsupported_scheme} =
               Blogmark.receive_deep_link(project.id, "bds://new-post?title=T")
    end
  end
end
