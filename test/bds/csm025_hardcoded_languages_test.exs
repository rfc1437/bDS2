defmodule BDS.CSM025HardcodedLanguagesTest do
  use ExUnit.Case, async: true

  alias BDS.Generation.Pagefind

  defp plan(main, languages) do
    %{language: main, blog_languages: languages}
  end

  defp html(path), do: {path, "<article data-pagefind-body><p>hello</p></article>"}

  describe "build_outputs/2 derives language prefixes from plan" do
    test "no hardcoded language prefixes in source" do
      source = File.read!("lib/bds/generation/pagefind.ex")

      refute source =~ ~s("de/"),
             "language prefixes must not be hardcoded — derive from plan.blog_languages"

      refute source =~ ~s("fr/")
      refute source =~ ~s("it/")
      refute source =~ ~s("es/")
    end

    test "main language index excludes other language paths" do
      outputs = [
        html("index.html"),
        html("about/index.html"),
        html("ja/index.html"),
        html("ko/index.html")
      ]

      result = Pagefind.build_outputs(plan("en", ["en", "ja", "ko"]), outputs)
      main_index = Enum.find(result, fn {path, _} -> path == "pagefind/index.json" end)
      assert main_index

      {_, json} = main_index
      decoded = Jason.decode!(json)
      urls = Enum.map(decoded["pages"], & &1["url"])
      assert "/index.html" in urls
      assert "/about/index.html" in urls
      refute "/ja/index.html" in urls
      refute "/ko/index.html" in urls
    end

    test "non-main language index includes only its own paths" do
      outputs = [
        html("index.html"),
        html("ja/index.html"),
        html("ja/about/index.html"),
        html("ko/index.html")
      ]

      result = Pagefind.build_outputs(plan("en", ["en", "ja", "ko"]), outputs)
      ja_index = Enum.find(result, fn {path, _} -> path == "ja/pagefind/index.json" end)
      assert ja_index

      {_, json} = ja_index
      decoded = Jason.decode!(json)
      urls = Enum.map(decoded["pages"], & &1["url"])
      assert "/ja/index.html" in urls
      assert "/ja/about/index.html" in urls
      refute "/index.html" in urls
      refute "/ko/index.html" in urls
    end

    test "works with arbitrary language codes not in old hardcoded list" do
      outputs = [
        html("index.html"),
        html("pt-br/index.html"),
        html("zh-cn/index.html")
      ]

      result = Pagefind.build_outputs(plan("en", ["en", "pt-br", "zh-cn"]), outputs)
      main_index = Enum.find(result, fn {path, _} -> path == "pagefind/index.json" end)
      {_, json} = main_index
      decoded = Jason.decode!(json)
      urls = Enum.map(decoded["pages"], & &1["url"])
      assert "/index.html" in urls
      refute "/pt-br/index.html" in urls
      refute "/zh-cn/index.html" in urls
    end

    test "single language blog has no exclusion prefixes" do
      outputs = [html("index.html"), html("about/index.html")]

      result = Pagefind.build_outputs(plan("en", ["en"]), outputs)
      assert length(result) == 3

      {_, json} = Enum.find(result, fn {path, _} -> path == "pagefind/index.json" end)
      decoded = Jason.decode!(json)
      assert length(decoded["pages"]) == 2
    end
  end
end
