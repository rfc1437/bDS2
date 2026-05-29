defmodule BDS.Generation.Pagefind do
  @moduledoc false

  @typedoc "An (relative_path, content) HTML output tuple."
  @type html_output :: {String.t(), String.t()}

  @typedoc "A (relative_path, content) generated file tuple."
  @type generated_file :: {String.t(), String.t()}

  @assets_dir Application.app_dir(:bds, "priv/preview_assets/assets")
  @ui_js_path Path.join(@assets_dir, "pagefind-ui.js")
  @ui_css_path Path.join(@assets_dir, "pagefind-ui.css")

  @external_resource @ui_js_path
  @external_resource @ui_css_path

  @ui_js File.read!(@ui_js_path)
  @ui_css File.read!(@ui_css_path)

  @doc """
  Build the per-language Pagefind index outputs (`pagefind/index.json`,
  `pagefind/pagefind-ui.js`, `pagefind/pagefind-ui.css`) for every blog
  language declared on the plan.

  The fragment index records one entry per indexable page, where indexable
  means the page carries a `data-pagefind-body` region. Each entry stores the
  page URL, its title, and the body text scoped to that region — mirroring
  Pagefind's behaviour of ignoring content outside `data-pagefind-body`.
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
        {Path.join(prefix ++ ["pagefind-ui.js"]), @ui_js},
        {Path.join(prefix ++ ["pagefind-ui.css"]), @ui_css}
      ]
    end)
  end

  defp pages_for_language(html_outputs, route_language, other_prefixes) do
    html_outputs
    |> Enum.filter(fn {relative_path, _content} ->
      String.ends_with?(relative_path, ".html") and
        language_match?(relative_path, route_language, other_prefixes)
    end)
    |> Enum.flat_map(fn {relative_path, content} ->
      case body_text(content) do
        nil ->
          []

        text ->
          [%{"url" => "/" <> relative_path, "title" => title(content), "text" => text}]
      end
    end)
  end

  defp language_match?(relative_path, nil, other_prefixes),
    do: not String.starts_with?(relative_path, other_prefixes)

  defp language_match?(relative_path, "", other_prefixes),
    do: language_match?(relative_path, nil, other_prefixes)

  defp language_match?(relative_path, route_language, _other_prefixes),
    do: String.starts_with?(relative_path, route_language <> "/")

  # Extract the indexable body text scoped to the data-pagefind-body element.
  # Returns nil when the page is not marked, so unmarked pages are excluded
  # from the index entirely (matching Pagefind semantics).
  defp body_text(content) do
    case Regex.run(~r/<([a-zA-Z0-9]+)[^>]*\bdata-pagefind-body\b[^>]*>/, content,
           return: :index
         ) do
      [{open_start, open_len}, {tag_start, tag_len}] ->
        tag = binary_part(content, tag_start, tag_len)
        region = scoped_region(content, tag, open_start + open_len)
        plain_text(region)

      _no_match ->
        nil
    end
  end

  # Capture the inner HTML of the marked element by balancing same-tag
  # open/close pairs from the opening tag onward.
  defp scoped_region(content, tag, body_start) do
    rest = binary_part(content, body_start, byte_size(content) - body_start)
    open_re = Regex.compile!("<#{tag}\\b", "i")
    close_re = Regex.compile!("</#{tag}\\s*>", "i")

    events =
      (Regex.scan(open_re, rest, return: :index) ++ Regex.scan(close_re, rest, return: :index))
      |> Enum.map(fn [{pos, _len}] -> pos end)
      |> Enum.map(fn pos -> {pos, event_kind(rest, pos, tag)} end)
      |> Enum.sort_by(&elem(&1, 0))

    close_at = balanced_close(events, 0)

    case close_at do
      nil -> rest
      pos -> binary_part(rest, 0, pos)
    end
  end

  defp event_kind(rest, pos, tag) do
    if String.starts_with?(binary_part(rest, pos, min(2 + byte_size(tag), byte_size(rest) - pos)), "</") do
      :close
    else
      :open
    end
  end

  defp balanced_close([], _depth), do: nil

  defp balanced_close([{pos, :close} | _rest], 0), do: pos

  defp balanced_close([{_pos, :close} | rest], depth),
    do: balanced_close(rest, depth - 1)

  defp balanced_close([{_pos, :open} | rest], depth),
    do: balanced_close(rest, depth + 1)

  defp title(content) do
    tag_text(content, ~r/<title[^>]*>(.*?)<\/title>/si) ||
      tag_text(content, ~r/<h1[^>]*>(.*?)<\/h1>/si) ||
      ""
  end

  defp tag_text(content, regex) do
    case Regex.run(regex, content) do
      [_full, raw] -> raw |> plain_text() |> nil_if_blank()
      _no_match -> nil
    end
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(value), do: value

  defp plain_text(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp route_language(main_language, language) when main_language == language, do: nil
  defp route_language(_main_language, language), do: language
end
