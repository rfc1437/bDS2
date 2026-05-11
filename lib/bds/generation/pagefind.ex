defmodule BDS.Generation.Pagefind do
  @moduledoc false

  @typedoc "An (relative_path, content) HTML output tuple."
  @type html_output :: {String.t(), String.t()}

  @typedoc "A (relative_path, content) generated file tuple."
  @type generated_file :: {String.t(), String.t()}

  @doc """
  Build the per-language Pagefind index outputs (`pagefind/index.json`,
  `pagefind/pagefind-ui.js`, `pagefind/pagefind-ui.css`) for every blog
  language declared on the plan.
  """
  @spec build_outputs(map(), [html_output()]) :: [generated_file()]
  def build_outputs(plan, html_outputs) do
    languages = Enum.uniq(plan.blog_languages)

    other_prefixes =
      languages
      |> Enum.reject(&(&1 == plan.language))
      |> Enum.map(&(&1 <> "/"))

    Enum.flat_map(languages, fn language ->
      route_language = route_language(plan.language, language)
      pages = pages_for_language(html_outputs, route_language, other_prefixes)

      prefix =
        if route_language in [nil, ""], do: ["pagefind"], else: [route_language, "pagefind"]

      [
        {Path.join(prefix ++ ["index.json"]),
         Jason.encode!(%{"language" => language, "pages" => pages})},
        {Path.join(prefix ++ ["pagefind-ui.js"]), ui_js(language)},
        {Path.join(prefix ++ ["pagefind-ui.css"]), ui_css()}
      ]
    end)
  end

  defp pages_for_language(html_outputs, route_language, other_prefixes) do
    html_outputs
    |> Enum.filter(fn {relative_path, _content} ->
      String.ends_with?(relative_path, ".html") and
        language_match?(relative_path, route_language, other_prefixes)
    end)
    |> Enum.map(fn {relative_path, content} ->
      %{
        "url" => "/" <> relative_path,
        "text" => text(content)
      }
    end)
  end

  defp language_match?(relative_path, nil, other_prefixes),
    do: not String.starts_with?(relative_path, other_prefixes)

  defp language_match?(relative_path, "", other_prefixes),
    do: language_match?(relative_path, nil, other_prefixes)

  defp language_match?(relative_path, route_language, _other_prefixes),
    do: String.starts_with?(relative_path, route_language <> "/")

  defp text(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp ui_js(language) do
    "window.bDSPagefind = { language: #{Jason.encode!(language)} };\n"
  end

  defp ui_css do
    ".pagefind-ui{display:block;}\n"
  end

  defp route_language(main_language, language) when main_language == language, do: nil
  defp route_language(_main_language, language), do: language
end
