defmodule BDS.Rendering.Filters do
  @moduledoc false

  use Liquex.Filter

  alias BDS.Slug

  def i18n(value, language, _context) do
    key = value |> to_string() |> String.trim()

    if key == "" do
      ""
    else
      BDS.Gettext.lgettext(language, "render", key)
    end
  end

  def markdown(
        value,
        _post_id,
        _post_data_json_by_id,
        canonical_post_paths,
        canonical_media_paths,
        language,
        _language_prefix,
        context
      ) do
    render_markdown(value, canonical_post_paths, canonical_media_paths, language, context)
  end

  def render_markdown(value, canonical_post_paths, canonical_media_paths, language, context) do
    value
    |> to_string()
    |> replace_built_in_macros(language, context)
    |> render_markdown_html()
    |> rewrite_rendered_html_urls(canonical_post_paths || %{}, canonical_media_paths || %{})
  end

  def slugify(value, _context) do
    value
    |> to_string()
    |> Slug.slugify()
  end

  defp replace_built_in_macros(content, language, context) do
    Regex.replace(~r/\[\[(\w+)(?:\s+([^\]]+))?\]\]/, content, fn full_match,
                                                                 macro_name,
                                                                 raw_params ->
      params = parse_macro_params(raw_params)

      case String.downcase(macro_name) do
        "youtube" ->
          render_macro_template(
            "macros/youtube",
            %{
              "id" => Map.get(params, "id", ""),
              "title" =>
                default_macro_title(
                  Map.get(params, "title"),
                  language,
                  "YouTube video"
                )
            },
            context
          )

        "vimeo" ->
          render_macro_template(
            "macros/vimeo",
            %{
              "id" => Map.get(params, "id", ""),
              "title" => default_macro_title(Map.get(params, "title"), language, "Vimeo video")
            },
            context
          )

        _other ->
          full_match
      end
    end)
  end

  defp default_macro_title(nil, language, translation),
    do: translated_macro_title(language, translation)

  defp default_macro_title("", language, translation),
    do: translated_macro_title(language, translation)

  defp default_macro_title(title, _language, _translation), do: title

  defp translated_macro_title(language, translation) do
    BDS.Gettext.lgettext(language, "render", translation)
  end

  defp parse_macro_params(nil), do: %{}
  defp parse_macro_params(""), do: %{}

  defp parse_macro_params(raw_params) do
    Regex.scan(~r/(\w+)=(?:"([^"]*)"|'([^']*)'|([^\s\]]+))/, raw_params, capture: :all_but_first)
    |> Enum.reduce(%{}, fn captures, acc ->
      case captures do
        [key, value] ->
          Map.put(acc, key, value)

        [key, double_quoted, single_quoted, bare] ->
          value = Enum.find([double_quoted, single_quoted, bare], &(&1 not in [nil, ""])) || ""
          Map.put(acc, key, value)

        _other ->
          acc
      end
    end)
  end

  defp render_macro_template(template_path, assigns, context) do
    case Map.get(assigns, "id") do
      "" ->
        ""

      nil ->
        ""

      _id ->
        template_source = Liquex.FileSystem.read_template_file(context.file_system, template_path)
        template_ast = Liquex.parse!(template_source)
        isolated_context = Liquex.Context.new_isolated_subscope(context, assigns)
        {result, _context} = Liquex.render!(template_ast, isolated_context)
        IO.iodata_to_binary(result)
    end
  rescue
    _error -> ""
  end

  defp render_markdown_html(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _messages} -> html
      {:error, html, _messages} -> html
    end
  end

  defp rewrite_rendered_html_urls(html, canonical_post_paths, canonical_media_paths) do
    html
    |> rewrite_attribute(
      "href",
      &normalize_post_href(&1, canonical_post_paths, canonical_media_paths)
    )
    |> rewrite_attribute("src", &normalize_media_src(&1, canonical_media_paths))
  end

  defp rewrite_attribute(html, attribute, rewriter) do
    Regex.replace(~r/\b#{attribute}=(['"])(.*?)\1/i, html, fn _full_match, quote, value ->
      rewritten = rewriter.(value)
      ~s(#{attribute}=#{quote}#{rewritten}#{quote})
    end)
  end

  defp normalize_post_href(raw_href, canonical_post_paths, canonical_media_paths) do
    cond do
      raw_href == "" ->
        raw_href

      external_or_special_url?(raw_href) ->
        raw_href

      true ->
        {path_part, suffix} = split_path_suffix(raw_href)

        case path_part do
          "/" <> _rest = value ->
            case canonical_post_path(value, canonical_post_paths) do
              nil -> normalize_media_src(raw_href, canonical_media_paths)
              canonical -> canonical <> suffix
            end

          _other ->
            raw_href
        end
    end
  end

  defp canonical_post_path(path_part, canonical_post_paths) do
    cond do
      Regex.match?(~r|^/\d{4}/\d{2}/\d{2}/[a-z0-9-]+(?:\.html?)?$|i, path_part) ->
        path_part |> String.replace(~r/\.html?$/i, "")

      match = Regex.run(~r|^/?post/([a-z0-9-]+(?:\.html?)?)$|i, path_part) ->
        slug = match |> Enum.at(1) |> String.replace(~r/\.html?$/i, "")
        Map.get(canonical_post_paths, slug)

      match = Regex.run(~r|^/?post/\d{4}/\d{1,2}/([a-z0-9-]+(?:\.html?)?)$|i, path_part) ->
        slug = match |> Enum.at(1) |> String.replace(~r/\.html?$/i, "")
        Map.get(canonical_post_paths, slug)

      match = Regex.run(~r|^/?posts/([a-z0-9-]+(?:\.html?)?)$|i, path_part) ->
        slug = match |> Enum.at(1) |> String.replace(~r/\.html?$/i, "")
        Map.get(canonical_post_paths, slug)

      match = Regex.run(~r|^/?posts/\d{4}/\d{1,2}/([a-z0-9-]+(?:\.html?)?)$|i, path_part) ->
        slug = match |> Enum.at(1) |> String.replace(~r/\.html?$/i, "")
        Map.get(canonical_post_paths, slug)

      true ->
        nil
    end
  end

  defp normalize_media_src(raw_src, canonical_media_paths) do
    cond do
      raw_src == "" ->
        raw_src

      external_or_special_url?(raw_src) ->
        raw_src

      true ->
        {path_part, suffix} = split_path_suffix(raw_src)

        case Regex.run(~r|^/?media/(\d{4})/(\d{2})/([^\s?#]+)$|i, path_part) do
          [_, year, month, filename] ->
            key = String.downcase(Path.join(["media", year, month, filename]))
            Map.get(canonical_media_paths, key, ensure_leading_slash(path_part)) <> suffix

          _other ->
            raw_src
        end
    end
  end

  defp external_or_special_url?(value) do
    normalized = String.trim(value)

    normalized == "" or String.starts_with?(normalized, ["#", "//"]) or
      Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, normalized)
  end

  defp split_path_suffix(value) do
    case Regex.run(~r/^([^?#]*)([?#].*)?$/, String.trim(value)) do
      [_, path_part, suffix] -> {path_part, suffix}
      [_, path_part] -> {path_part, ""}
      _other -> {value, ""}
    end
  end

  defp ensure_leading_slash("/" <> _rest = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
