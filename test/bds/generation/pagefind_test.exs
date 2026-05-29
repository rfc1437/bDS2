defmodule BDS.Generation.PagefindTest do
  use ExUnit.Case, async: true

  alias BDS.Generation.Pagefind

  defp plan(language, blog_languages), do: %{language: language, blog_languages: blog_languages}

  defp index_for(outputs, relative_path) do
    {_path, content} = Enum.find(outputs, fn {path, _} -> path == relative_path end)
    Jason.decode!(content)
  end

  defp content_for(outputs, relative_path) do
    {_path, content} = Enum.find(outputs, fn {path, _} -> path == relative_path end)
    content
  end

  test "indexes only pages marked with data-pagefind-body and scopes text to that region" do
    post_html = """
    <html><head><title>My First Post</title></head>
    <body>
      <nav>Home Archive Contact ignored-nav-term</nav>
      <article data-pagefind-body><h1>My First Post</h1><p>Searchable elixir content.</p></article>
      <footer>footer-term</footer>
    </body></html>
    """

    list_html = "<html><head><title>Home</title></head><body><ul>list page</ul></body></html>"

    outputs =
      Pagefind.build_outputs(plan("en", ["en"]), [
        {"posts/first.html", post_html},
        {"index.html", list_html}
      ])

    index = index_for(outputs, "pagefind/index.json")

    assert index["language"] == "en"
    # Only the marked post page is indexed; the unmarked list page is excluded.
    urls = Enum.map(index["pages"], & &1["url"])
    assert "/posts/first.html" in urls
    refute "/index.html" in urls

    page = Enum.find(index["pages"], &(&1["url"] == "/posts/first.html"))
    assert page["title"] == "My First Post"
    # Body text is scoped to data-pagefind-body — nav/footer text is excluded.
    assert page["text"] =~ "Searchable elixir content"
    refute page["text"] =~ "ignored-nav-term"
    refute page["text"] =~ "footer-term"
  end

  test "builds a separate index per language scoped by route prefix" do
    en_post =
      "<html><head><title>EN</title></head><body><article data-pagefind-body>english body</article></body></html>"

    de_post =
      "<html><head><title>DE</title></head><body><article data-pagefind-body>deutscher text</article></body></html>"

    outputs =
      Pagefind.build_outputs(plan("en", ["en", "de"]), [
        {"posts/first.html", en_post},
        {"de/posts/first.html", de_post}
      ])

    en_index = index_for(outputs, "pagefind/index.json")
    de_index = index_for(outputs, "de/pagefind/index.json")

    assert en_index["language"] == "en"
    assert Enum.map(en_index["pages"], & &1["url"]) == ["/posts/first.html"]

    assert de_index["language"] == "de"
    assert Enum.map(de_index["pages"], & &1["url"]) == ["/de/posts/first.html"]
  end

  test "emits a functional PagefindUI script and stylesheet per language" do
    outputs =
      Pagefind.build_outputs(plan("en", ["en"]), [
        {"posts/first.html",
         "<html><head><title>T</title></head><body><article data-pagefind-body>b</article></body></html>"}
      ])

    js = content_for(outputs, "pagefind/pagefind-ui.js")
    css = content_for(outputs, "pagefind/pagefind-ui.css")

    # Real UI defines the PagefindUI global the search runtime instantiates.
    assert js =~ "PagefindUI"
    refute js =~ "window.bDSPagefind"
    # Stylesheet carries real UI selectors, not a one-liner stub.
    assert css =~ ".pagefind-ui__results"
  end
end
