defmodule BDS.Rendering.Filters do
  @moduledoc false

  use Liquex.Filter

  import Ecto.Query

  alias BDS.Slug
  alias BDS.{Repo}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.{Post, PostMedia}
  alias BDS.Tags.Tag
  require Logger

  @spec i18n(term(), String.t(), Liquex.Context.t()) :: String.t()
  def i18n(value, language, _context) do
    key = value |> to_string() |> String.trim()

    if key == "" do
      ""
    else
      BDS.Gettext.lgettext(language, "render", key)
    end
  end

  @spec markdown(
          term(),
          term(),
          term(),
          map(),
          map(),
          String.t(),
          term(),
          Liquex.Context.t()
        ) :: String.t()
  def markdown(
        value,
        post_id,
        _post_data_json_by_id,
        canonical_post_paths,
        canonical_media_paths,
        language,
        _language_prefix,
        context
      ) do
    render_markdown(
      value,
      canonical_post_paths,
      canonical_media_paths,
      language,
      context,
      post_id
    )
  end

  @spec render_markdown(term(), map() | nil, map() | nil, String.t(), Liquex.Context.t(), term()) ::
          String.t()
  def render_markdown(
        value,
        canonical_post_paths,
        canonical_media_paths,
        language,
        context,
        post_id \\ nil
      ) do
    value
    |> to_string()
    |> replace_built_in_macros(language, context, post_id)
    |> render_markdown_html()
    |> rewrite_rendered_html_urls(canonical_post_paths || %{}, canonical_media_paths || %{})
  end

  @spec slugify(term(), Liquex.Context.t()) :: String.t()
  def slugify(value, _context) do
    value
    |> to_string()
    |> Slug.slugify()
  end

  defp replace_built_in_macros(content, language, context, post_id) do
    Regex.replace(~r/\[\[(\w+)(?:\s+([^\]]+))?\]\]/, content, fn full_match,
                                                                 macro_name,
                                                                 raw_params ->
      params = parse_macro_params(raw_params)

      case String.downcase(macro_name) do
        "youtube" ->
          render_video_macro("youtube", params, language, "YouTube video", context)

        "vimeo" ->
          render_video_macro("vimeo", params, language, "Vimeo video", context)

        "gallery" ->
          render_gallery_macro(context, params, post_id)

        "photo_archive" ->
          render_photo_archive_macro(context, params)

        "tag_cloud" ->
          render_tag_cloud_macro(context, params)

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
    case BDS.Rendering.FileSystem.try_read(context.file_system, template_path) do
      {:ok, template_source} ->
        render_macro_source(template_path, template_source, assigns, context)

      {:error, :enoent} ->
        require Logger
        Logger.warning("Macro template not found: #{template_path}")
        ""
    end
  end

  defp render_macro_source(template_path, template_source, assigns, context) do
    with {:ok, template_ast} <- Liquex.parse(template_source, BDS.Rendering.LiquidParser),
         {:ok, rendered} <- safe_liquex_render(template_ast, context, assigns) do
      rendered
    else
      {:error, reason, line} ->
        require Logger

        Logger.warning(
          "Macro template parse failed (#{template_path}): #{reason} at line #{line}"
        )

        ""

      {:error, message} ->
        require Logger
        Logger.warning("Macro template render failed (#{template_path}): #{message}")
        ""
    end
  end

  defp safe_liquex_render(template_ast, context, assigns) do
    isolated_context = Liquex.Context.new_isolated_subscope(context, assigns)

    {result, _context} = Liquex.render!(template_ast, isolated_context)
    {:ok, IO.iodata_to_binary(result)}
  rescue
    e in Liquex.Error -> {:error, e.message}
  end

  defp render_markdown_html(markdown) do
    # Macros above inject raw HTML (gallery, video embeds), so the render path
    # must pass HTML through untouched. unsafe: true matches the prior Earmark
    # no-escape behavior.
    case MDEx.to_html(markdown, render: [unsafe: true]) do
      {:ok, html} -> html
      {:error, _reason} -> markdown
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

  # ── Built-in macro renderers ───────────────────────────────────────────────

  defp render_gallery_macro(context, params, post_id) do
    normalized_post_id = if is_binary(post_id), do: post_id, else: ""
    items = if is_binary(post_id), do: gallery_items(post_id), else: []

    render_gallery_template(context, params, normalized_post_id, items)
  end

  defp render_photo_archive_macro(context, params) do
    language = macro_language(context)
    project_id = project_id_from_context(context)

    months =
      if project_id do
        media_month_archive(project_id, Map.get(params, "year"), Map.get(params, "month"))
      else
        []
      end

    render_macro_template(
      "macros/photo-archive",
      %{
        "root_classes" => "macro-photo-archive",
        "data_attrs" => [],
        "months" => months,
        "empty_label" => BDS.Gettext.lgettext(language, "render", "No photos found")
      },
      context
    )
  end

  defp render_tag_cloud_macro(context, params) do
    language = macro_language(context)
    project_id = project_id_from_context(context)

    {words_json, width, height} =
      if project_id do
        build_tag_cloud_data(project_id)
      else
        {nil, 800, 400}
      end

    render_macro_template(
      "macros/tag-cloud",
      %{
        "orientation" => Map.get(params, "orientation", "horizontal"),
        "words_json" => words_json,
        "width" => Map.get(params, "width", width),
        "height" => Map.get(params, "height", height),
        "aria_label" => "Tag cloud",
        "empty_label" => BDS.Gettext.lgettext(language, "render", "No tags")
      },
      context
    )
  end

  defp render_video_macro(kind, params, language, translation, context) do
    render_macro_template(
      "macros/#{kind}",
      %{
        "id" => Map.get(params, "id", ""),
        "title" => default_macro_title(Map.get(params, "title"), language, translation)
      },
      context
    )
  end

  defp render_gallery_template(context, params, post_id, items) do
    render_macro_template(
      "macros/gallery",
      %{
        "columns" => normalize_columns(Map.get(params, "columns", "3"), 3, 1, 6),
        "post_id" => post_id,
        "items" => items,
        "caption" => Map.get(params, "caption"),
        "empty_label" => BDS.Gettext.lgettext(macro_language(context), "render", "No images")
      },
      context
    )
  end

  defp gallery_items(post_id) do
    post_id
    |> linked_media_images()
    |> Enum.map(fn media ->
      %{
        "media_path" => "/#{media.file_path}",
        "title" => media.title || media.original_name,
        "alt" => media.alt || media.title || media.original_name,
        "group_name" => post_id
      }
    end)
  end

  # ── Data queries for macros ────────────────────────────────────────────────

  defp linked_media_images(post_id) do
    Repo.all(
      from pm in PostMedia,
        join: m in MediaRecord,
        on: pm.media_id == m.id,
        where: pm.post_id == ^post_id,
        where: like(m.mime_type, "image/%"),
        order_by: [asc: pm.sort_order, asc: pm.media_id],
        select: m
    )
  end

  defp media_month_archive(project_id, year, month) do
    query =
      from m in MediaRecord,
        where: m.project_id == ^project_id,
        where: like(m.mime_type, "image/%"),
        order_by: [desc: m.created_at],
        select: m

    query =
      if year do
        year_int = parse_integer(year)

        if month do
          month_int = parse_integer(month)
          start_ts = month_start_ms(year_int, month_int)
          end_ts = month_end_ms(year_int, month_int)

          from m in query,
            where: m.created_at >= ^start_ts and m.created_at <= ^end_ts
        else
          start_ts = month_start_ms(year_int, 1)
          end_ts = month_end_ms(year_int, 12)

          from m in query,
            where: m.created_at >= ^start_ts and m.created_at <= ^end_ts
        end
      else
        from m in query, limit: 200
      end

    media_records =
      query
      |> Repo.all()
      |> group_by_media_month()

    if year == nil do
      Enum.take(media_records, 10)
    else
      media_records
    end
  end

  defp group_by_media_month(media_records) do
    month_names = %{
      1 => "January",
      2 => "February",
      3 => "March",
      4 => "April",
      5 => "May",
      6 => "June",
      7 => "July",
      8 => "August",
      9 => "September",
      10 => "October",
      11 => "November",
      12 => "December"
    }

    media_records
    |> Enum.group_by(fn m ->
      date = DateTime.from_unix!(div(m.created_at, 1000))
      {date.year, date.month}
    end)
    |> Enum.sort_by(fn {{y, m}, _} -> {y, m} end, :desc)
    |> Enum.map(fn {{year, month}, items} ->
      %{
        "label" => "#{Map.get(month_names, month)} #{year}",
        "items" =>
          Enum.map(items, fn m ->
            %{
              "media_path" => "/#{m.file_path}",
              "title" => m.title || m.original_name,
              "alt" => m.alt || m.title || m.original_name,
              "group_name" => "#{year}-#{month}"
            }
          end)
      }
    end)
  end

  defp build_tag_cloud_data(project_id) do
    tag_colors =
      Repo.all(
        from tag in Tag,
          where: tag.project_id == ^project_id,
          where: not is_nil(tag.color) and tag.color != "",
          select: {tag.name, tag.color}
      )
      |> Map.new()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT trim(je.value) AS tag, COUNT(*) AS cnt
        FROM posts, json_each(posts.tags) je
        WHERE posts.project_id = ?1
          AND trim(je.value) != ''
        GROUP BY tag
        ORDER BY cnt DESC, lower(tag) ASC
        """,
        [project_id]
      )

    tag_entries =
      Enum.map(rows, fn [tag, count] ->
        %{tag: tag, count: count, color: Map.get(tag_colors, tag)}
      end)

    if tag_entries == [] do
      {nil, 0, 0}
    else
      max_count = Enum.map(tag_entries, & &1.count) |> Enum.max()
      min_count = Enum.map(tag_entries, & &1.count) |> Enum.min()
      range = max(max_count - min_count, 1)

      words =
        Enum.map(tag_entries, fn %{tag: tag, count: count, color: color} ->
          size = 12.0 + (count - min_count) / range * 28.0
          %{"text" => tag, "size" => size, "color" => color || "var(--accent-color)"}
        end)

      {Jason.encode!(words), 800, 400}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp macro_language(context), do: Access.get(context, "language") || "en"

  defp project_id_from_context(context) do
    post = Access.get(context, "post") || %{}
    post["project_id"] || Access.get(post, :project_id) || project_id_from_post(context)
  end

  defp project_id_from_post(context) do
    post_id =
      Access.get(Access.get(context, "post") || %{}, "id") ||
        Access.get(Access.get(context, "post") || %{}, :id)

    if is_binary(post_id) do
      case Repo.one(from p in Post, where: p.id == ^post_id, select: p.project_id) do
        nil -> nil
        project_id -> project_id
      end
    end
  end

  defp normalize_columns(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n |> max(min) |> min(max)
      _ -> default
    end
  end

  defp normalize_columns(value, _default, min, max) when is_integer(value),
    do: value |> max(min) |> min(max)

  defp normalize_columns(_value, default, _min, _max), do: default

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_value), do: nil

  defp month_start_ms(year, month) do
    case DateTime.from_iso8601("#{year}-#{pad(month)}-01T00:00:00Z") do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp month_end_ms(year, month) do
    last_day =
      if month == 12 do
        31
      else
        case DateTime.from_iso8601("#{year}-#{pad(month + 1)}-01T00:00:00Z") do
          {:ok, dt, _} ->
            dt |> DateTime.add(-1, :second) |> DateTime.to_date() |> Map.get(:day)

          _ ->
            31
        end
      end

    case DateTime.from_iso8601("#{year}-#{pad(month)}-#{pad(last_day)}T23:59:59.999Z") do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp pad(n) when is_integer(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
