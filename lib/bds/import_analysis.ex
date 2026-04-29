defmodule BDS.ImportAnalysis do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags.Tag
  alias BDS.WxrParser

  @shortcode_regex ~r/(?<!\[)\[(\w+)([^\]]*?)(?:\s*\/)?\](?!\])/u
  @param_regex ~r/(\w+)=(?:"([^"]*)"|'([^']*)'|([^\s\]"']+))/u

  def analyze_wxr(project_id, wxr_file_path, uploads_folder_path \\ nil)
      when is_binary(project_id) and is_binary(wxr_file_path) do
    wxr_data = WxrParser.parse_file(wxr_file_path)
    {:ok, build_report(project_id, wxr_data, wxr_file_path, uploads_folder_path)}
  rescue
    error -> {:error, %{message: Exception.message(error)}}
  end

  defp build_report(project_id, wxr_data, wxr_file_path, uploads_folder_path) do
    existing_posts = Repo.all(from post in Post, where: post.project_id == ^project_id)
    existing_media = Repo.all(from media in Media, where: media.project_id == ^project_id)
    existing_tag_names = Repo.all(from tag in Tag, where: tag.project_id == ^project_id, select: tag.name)
    existing_tag_set = existing_tag_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    posts_by_slug = Map.new(existing_posts, &{&1.slug, &1})

    posts_by_checksum =
      existing_posts
      |> Enum.reject(&is_nil(&1.checksum))
      |> Map.new(&{&1.checksum, &1})

    media_by_name = Map.new(existing_media, &{String.downcase(&1.original_name), &1})

    media_by_checksum =
      existing_media
      |> Enum.reject(&is_nil(&1.checksum))
      |> Map.new(&{&1.checksum, &1})

    analyzed_posts = Enum.map(wxr_data.posts, &analyze_post_item(&1, posts_by_slug, posts_by_checksum, "post"))
    analyzed_pages = Enum.map(wxr_data.pages, &analyze_post_item(&1, posts_by_slug, posts_by_checksum, "page"))

    analyzed_media =
      Enum.map(wxr_data.media, &analyze_media_item(&1, uploads_folder_path, media_by_name, media_by_checksum))

    category_items = Enum.map(wxr_data.categories, &analyze_taxonomy_item(&1, existing_tag_set))
    tag_items = Enum.map(wxr_data.tags, &analyze_taxonomy_item(&1, existing_tag_set))

    %{
      source_file: wxr_file_path,
      site_info: %{
        title: wxr_data.site.title,
        url: wxr_data.site.link,
        language: wxr_data.site.language,
        source_file: wxr_file_path
      },
      post_stats: summarize_post_items(analyzed_posts),
      page_stats: summarize_post_items(analyzed_pages),
      media_stats: summarize_media_items(analyzed_media),
      category_stats: summarize_taxonomy_items(category_items),
      tag_stats: summarize_taxonomy_items(tag_items),
      date_distribution: date_distribution(analyzed_posts, analyzed_pages, analyzed_media),
      conflicts: conflicts(analyzed_posts, analyzed_pages, analyzed_media),
      macros: macros(wxr_data.posts ++ wxr_data.pages),
      items: %{
        posts: Enum.map(analyzed_posts, &summary_item/1),
        pages: Enum.map(analyzed_pages, &summary_item/1),
        media: Enum.map(analyzed_media, &summary_item/1),
        categories: category_items,
        tags: tag_items
      },
      details: %{
        posts: analyzed_posts,
        pages: analyzed_pages,
        media: analyzed_media
      }
    }
  end

  defp analyze_post_item(wxr_post, posts_by_slug, posts_by_checksum, item_type) do
    content_markdown = html_to_markdown(wxr_post.content || "")
    content_checksum = sha256(content_markdown)
    existing_by_slug = Map.get(posts_by_slug, wxr_post.slug)
    existing_by_checksum = Map.get(posts_by_checksum, content_checksum)

    {status, existing} =
      cond do
        existing_by_slug && existing_by_slug.checksum == content_checksum && not is_nil(existing_by_slug.checksum) -> {"update", existing_by_slug}
        existing_by_slug -> {"conflict", existing_by_slug}
        existing_by_checksum -> {"duplicate", existing_by_checksum}
        true -> {"new", nil}
      end

    %{
      item_type: item_type,
      wp_id: wxr_post.wp_id,
      title: wxr_post.title,
      slug: wxr_post.slug,
      status: status,
      resolution: if(status == "conflict", do: "skip", else: nil),
      existing_id: existing && existing.id,
      existing_title: existing && existing.title,
      author: blank_to_nil(wxr_post.creator),
      excerpt: blank_to_nil(wxr_post.excerpt),
      categories: wxr_post.categories,
      tags: wxr_post.tags,
      wp_status: blank_to_nil(wxr_post.status),
      content_markdown: content_markdown,
      content_checksum: content_checksum,
      content_preview: String.slice(content_markdown, 0, 200),
      created_at: wxr_post.post_date || wxr_post.pub_date,
      updated_at: wxr_post.post_modified || wxr_post.post_date || wxr_post.pub_date,
      published_at: wxr_post.pub_date
    }
  end

  defp analyze_media_item(wxr_media, uploads_folder_path, media_by_name, media_by_checksum) do
    source_file =
      case uploads_folder_path do
        nil -> nil
        "" -> nil
        path -> Path.join(path, wxr_media.relative_path)
      end

    {status, checksum, existing} =
      cond do
        is_nil(source_file) or not File.exists?(source_file) ->
          {"missing", nil, nil}

        true ->
          binary = File.read!(source_file)
          file_checksum = md5(binary)
          existing_by_name = Map.get(media_by_name, String.downcase(wxr_media.filename))
          existing_by_checksum = Map.get(media_by_checksum, file_checksum)

          cond do
            existing_by_name && existing_by_name.checksum == file_checksum && not is_nil(existing_by_name.checksum) -> {"update", file_checksum, existing_by_name}
            existing_by_name -> {"conflict", file_checksum, existing_by_name}
            existing_by_checksum -> {"duplicate", file_checksum, existing_by_checksum}
            true -> {"new", file_checksum, nil}
          end
      end

    %{
      item_type: "media",
      wp_id: wxr_media.wp_id,
      title: wxr_media.title,
      filename: wxr_media.filename,
      relative_path: wxr_media.relative_path,
      status: status,
      resolution: if(status == "conflict", do: "skip", else: nil),
      existing_id: existing && existing.id,
      existing_title: existing && existing.title,
      mime_type: wxr_media.mime_type,
      description: blank_to_nil(wxr_media.description),
      parent_wp_id: wxr_media.parent_id,
      source_file: source_file,
      checksum: checksum,
      created_at: wxr_media.pub_date
    }
  end

  defp analyze_taxonomy_item(item, existing_tag_set) do
    exists_in_project = MapSet.member?(existing_tag_set, String.downcase(item.name))

    %{
      name: item.name,
      slug: item.slug,
      exists_in_project: exists_in_project,
      mapped_to: nil
    }
  end

  defp summary_item(%{item_type: "media"} = item) do
    base = %{
      item_type: item.item_type,
      title: item.title,
      filename: item.filename,
      relative_path: item.relative_path,
      status: item.status
    }

    maybe_put(base, :resolution, item.resolution)
  end

  defp summary_item(item) do
    base = %{
      item_type: item.item_type,
      title: item.title,
      slug: item.slug,
      status: item.status
    }

    maybe_put(base, :resolution, item.resolution)
  end

  defp summarize_post_items(items) do
    %{
      new_count: count_status(items, "new"),
      update_count: count_status(items, "update"),
      conflict_count: count_status(items, "conflict"),
      duplicate_count: count_status(items, "duplicate")
    }
  end

  defp summarize_media_items(items) do
    %{
      new_count: count_status(items, "new"),
      update_count: count_status(items, "update"),
      conflict_count: count_status(items, "conflict"),
      duplicate_count: count_status(items, "duplicate"),
      missing_count: count_status(items, "missing")
    }
  end

  defp summarize_taxonomy_items(items) do
    %{
      existing_count: Enum.count(items, & &1.exists_in_project),
      mapped_count: Enum.count(items, &(not &1.exists_in_project and not is_nil(&1.mapped_to))),
      new_count: Enum.count(items, &(not &1.exists_in_project and is_nil(&1.mapped_to)))
    }
  end

  defp date_distribution(posts, pages, media) do
    combined_posts = posts ++ pages

    post_counts = Enum.reduce(combined_posts, %{}, &increment_year(&1.created_at || &1.published_at, &2))
    media_counts = Enum.reduce(media, %{}, &increment_year(&1.created_at, &2))

    post_counts
    |> Map.keys()
    |> Enum.concat(Map.keys(media_counts))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn year ->
      %{
        year: year,
        post_count: Map.get(post_counts, year, 0),
        media_count: Map.get(media_counts, year, 0)
      }
    end)
  end

  defp conflicts(posts, pages, media) do
    (posts ++ pages ++ media)
    |> Enum.filter(&(&1.status == "conflict"))
    |> Enum.map(fn item ->
      %{
        item_type: item.item_type,
        item_name: Map.get(item, :slug) || Map.get(item, :filename),
        resolution: item.resolution || "skip",
        source_title: item.title,
        existing_title: item.existing_title
      }
    end)
  end

  defp macros(items) do
    items
    |> Enum.flat_map(&discover_item_macros/1)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, usages} ->
      %{
        name: name,
        usage_count: length(usages),
        parameters: usages |> Enum.flat_map(& &1.parameters) |> Enum.uniq() |> Enum.sort(),
        validation_status: "unknown"
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp discover_item_macros(item) do
    Regex.scan(@shortcode_regex, item.content || "")
    |> Enum.map(fn [_match, name, raw_params] ->
      %{
        name: String.downcase(name),
        parameters: macro_parameters(raw_params)
      }
    end)
  end

  defp macro_parameters(raw_params) do
    Regex.scan(@param_regex, raw_params)
    |> Enum.map(fn [_, key | _rest] -> key end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp increment_year(nil, acc), do: acc

  defp increment_year(value, acc) do
    case year_from(value) do
      nil -> acc
      year -> Map.update(acc, year, 1, &(&1 + 1))
    end
  end

  defp year_from(value) when is_integer(value), do: value

  defp year_from(value) when is_binary(value) do
    case Regex.run(~r/(\d{4})/, value) do
      [_, year] -> String.to_integer(year)
      _other -> nil
    end
  end

  defp year_from(_value), do: nil

  defp count_status(items, status), do: Enum.count(items, &(&1.status == status))

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp md5(binary) do
    :md5
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
  end

  defp html_to_markdown(content) do
    content
    |> to_string()
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r|</p>|i, "\n\n")
    |> String.replace(~r|<p[^>]*>|i, "")
    |> String.replace(~r|<strong>(.*?)</strong>|is, "**\\1**")
    |> String.replace(~r|<b>(.*?)</b>|is, "**\\1**")
    |> String.replace(~r|<em>(.*?)</em>|is, "*\\1*")
    |> String.replace(~r|<i>(.*?)</i>|is, "*\\1*")
    |> String.replace(~r|<code>(.*?)</code>|is, "`\\1`")
    |> String.replace(~r|<[^>]+>|u, "")
    |> HtmlEntities.decode()
    |> transform_shortcodes()
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  defp transform_shortcodes(content) do
    Regex.replace(@shortcode_regex, content, fn _match, name, raw_params ->
      inner = String.trim("#{name}#{raw_params}")
      "[[#{inner}]]"
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
