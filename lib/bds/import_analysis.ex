defmodule BDS.ImportAnalysis do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags.Tag
  alias BDS.WxrParser

  @shortcode_regex ~r/(?<!\[)\[(\w+)([^\]]*?)(?:\s*\/)?\](?!\])/u
  @param_regex ~r/(\w+)=(?:"([^"]*)"|'([^']*)'|([^\s\]"']+))/u

  def analyze_wxr(project_id, wxr_file_path), do: analyze_wxr(project_id, wxr_file_path, nil, [])

  def analyze_wxr(project_id, wxr_file_path, uploads_folder_path)
      when is_binary(project_id) and is_binary(wxr_file_path) do
    analyze_wxr(project_id, wxr_file_path, uploads_folder_path, [])
  end

  def analyze_wxr(project_id, wxr_file_path, uploads_folder_path, opts)
      when is_binary(project_id) and is_binary(wxr_file_path) and is_list(opts) do
    on_progress = Keyword.get(opts, :on_progress, fn _step, _detail -> :ok end)
    wxr_data = WxrParser.parse_file(wxr_file_path)
    {:ok, build_report(project_id, wxr_data, wxr_file_path, uploads_folder_path, on_progress)}
  rescue
    error ->
      Logger.warning(
        "import analysis failed project_id=#{project_id} file=#{wxr_file_path}: #{Exception.message(error)}"
      )

      {:error, %{message: Exception.message(error)}}
  end

  defp build_report(project_id, wxr_data, wxr_file_path, uploads_folder_path, on_progress) do
    notify_progress(on_progress, "Loading existing posts...")
    existing_posts = Repo.all(from post in Post, where: post.project_id == ^project_id)

    notify_progress(
      on_progress,
      "Loading existing media...",
      "#{length(existing_posts)} posts in project"
    )

    existing_media = Repo.all(from media in Media, where: media.project_id == ^project_id)

    notify_progress(
      on_progress,
      "Loading existing tags...",
      "#{length(existing_media)} media in project"
    )

    existing_tag_names =
      Repo.all(from tag in Tag, where: tag.project_id == ^project_id, select: tag.name)

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

    notify_progress(
      on_progress,
      "Analyzing posts...",
      "#{length(wxr_data.posts)} posts to analyze"
    )

    analyzed_posts =
      Enum.map(wxr_data.posts, &analyze_post_item(&1, posts_by_slug, posts_by_checksum, "post"))

    notify_progress(
      on_progress,
      "Analyzing pages...",
      "#{length(wxr_data.pages)} pages to analyze"
    )

    analyzed_pages =
      Enum.map(wxr_data.pages, &analyze_post_item(&1, posts_by_slug, posts_by_checksum, "page"))

    notify_progress(
      on_progress,
      "Analyzing media files...",
      "#{length(wxr_data.media)} media files to analyze"
    )

    analyzed_media =
      Enum.map(
        wxr_data.media,
        &analyze_media_item(&1, uploads_folder_path, media_by_name, media_by_checksum)
      )

    notify_progress(on_progress, "Processing categories and tags...")
    category_items = Enum.map(wxr_data.categories, &analyze_taxonomy_item(&1, existing_tag_set))
    tag_items = Enum.map(wxr_data.tags, &analyze_taxonomy_item(&1, existing_tag_set))

    notify_progress(on_progress, "Discovering macros...")
    macro_summary = analyze_macros(wxr_data.posts ++ wxr_data.pages)

    posts_only = Enum.filter(analyzed_posts, &(&1.post_type == "post"))
    other_posts = Enum.reject(analyzed_posts, &(&1.post_type == "post"))

    %{
      source_file: wxr_file_path,
      site_info: %{
        title: wxr_data.site.title,
        url: wxr_data.site.link,
        language: wxr_data.site.language,
        source_file: wxr_file_path
      },
      post_stats: summarize_post_items(posts_only),
      other_stats: summarize_other_items(other_posts),
      page_stats: summarize_post_items(analyzed_pages),
      media_stats: summarize_media_items(analyzed_media),
      category_stats: summarize_taxonomy_items(category_items),
      tag_stats: summarize_taxonomy_items(tag_items),
      date_distribution: date_distribution(analyzed_posts, analyzed_pages, analyzed_media),
      conflicts: conflicts(analyzed_posts, analyzed_pages, analyzed_media),
      macros: macro_summary,
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
        existing_by_slug && existing_by_slug.checksum == content_checksum &&
            not is_nil(existing_by_slug.checksum) ->
          {"update", existing_by_slug}

        existing_by_slug ->
          {"conflict", existing_by_slug}

        existing_by_checksum ->
          {"content-duplicate", existing_by_checksum}

        true ->
          {"new", nil}
      end

    %{
      item_type: item_type,
      post_type: wxr_post.post_type || item_type,
      wp_id: wxr_post.wp_id,
      title: wxr_post.title,
      slug: wxr_post.slug,
      status: status,
      resolution: if(status == "conflict", do: "ignore", else: nil),
      existing_id: existing && existing.id,
      existing_title: existing && existing.title,
      author: BDS.MapUtils.blank_to_nil(wxr_post.creator),
      excerpt: BDS.MapUtils.blank_to_nil(wxr_post.excerpt),
      categories: wxr_post.categories,
      tags: wxr_post.tags,
      wp_status: BDS.MapUtils.blank_to_nil(wxr_post.status),
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
            existing_by_name && existing_by_name.checksum == file_checksum &&
                not is_nil(existing_by_name.checksum) ->
              {"update", file_checksum, existing_by_name}

            existing_by_name ->
              {"conflict", file_checksum, existing_by_name}

            existing_by_checksum ->
              {"content-duplicate", file_checksum, existing_by_checksum}

            true ->
              {"new", file_checksum, nil}
          end
      end

    %{
      item_type: "media",
      wp_id: wxr_media.wp_id,
      title: wxr_media.title,
      filename: wxr_media.filename,
      relative_path: wxr_media.relative_path,
      url: wxr_media.url,
      status: status,
      resolution: if(status == "conflict", do: "ignore", else: nil),
      existing_id: existing && existing.id,
      existing_title: existing && existing.title,
      mime_type: wxr_media.mime_type,
      description: BDS.MapUtils.blank_to_nil(wxr_media.description),
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

    BDS.MapUtils.maybe_put(base, :resolution, item.resolution)
  end

  defp summary_item(item) do
    base = %{
      item_type: item.item_type,
      post_type: Map.get(item, :post_type, item.item_type),
      title: item.title,
      slug: item.slug,
      status: item.status
    }

    BDS.MapUtils.maybe_put(base, :resolution, item.resolution)
  end

  defp summarize_post_items(items) do
    %{
      new_count: count_status(items, "new"),
      update_count: count_status(items, "update"),
      conflict_count: count_status(items, "conflict"),
      duplicate_count: count_status(items, "content-duplicate")
    }
  end

  defp summarize_other_items(items) do
    %{
      new_count: count_status(items, "new"),
      update_count: count_status(items, "update"),
      conflict_count: count_status(items, "conflict"),
      duplicate_count: count_status(items, "content-duplicate"),
      types: items |> Enum.map(&Map.get(&1, :post_type)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp summarize_media_items(items) do
    %{
      new_count: count_status(items, "new"),
      update_count: count_status(items, "update"),
      conflict_count: count_status(items, "conflict"),
      duplicate_count: count_status(items, "content-duplicate"),
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

    post_counts =
      Enum.reduce(combined_posts, %{}, &increment_year(&1.created_at || &1.published_at, &2))

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
        resolution: item.resolution || "ignore",
        source_title: item.title,
        existing_title: item.existing_title
      }
    end)
  end

  defp analyze_macros(items) do
    macro_map =
      Enum.reduce(items, %{}, fn item, acc ->
        slug = Map.get(item, :slug)

        Regex.scan(@shortcode_regex, item.content || "")
        |> Enum.reduce(acc, fn [_match, name, raw_params], inner_acc ->
          name = String.downcase(name)
          params = parse_macro_params(raw_params)
          params_key = serialize_params(params)

          existing =
            Map.get(inner_acc, name, %{
              name: name,
              total_count: 0,
              usages: %{},
              post_slugs: MapSet.new()
            })

          usage =
            existing.usages
            |> Map.get(params_key, %{params: params, count: 0})
            |> Map.update(:count, 1, &(&1 + 1))

          updated = %{
            existing
            | total_count: existing.total_count + 1,
              usages: Map.put(existing.usages, params_key, usage),
              post_slugs:
                if(is_binary(slug),
                  do: MapSet.put(existing.post_slugs, slug),
                  else: existing.post_slugs
                )
          }

          Map.put(inner_acc, name, updated)
        end)
      end)

    discovered =
      macro_map
      |> Map.values()
      |> Enum.map(fn macro ->
        %{
          name: macro.name,
          mapped: false,
          total_count: macro.total_count,
          usages:
            macro.usages
            |> Map.values()
            |> Enum.map(fn usage ->
              %{
                params: usage.params,
                count: usage.count,
                validation_status: "unknown"
              }
            end),
          post_slugs: MapSet.to_list(macro.post_slugs) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{
      total: length(discovered),
      mapped_count: Enum.count(discovered, & &1.mapped),
      unmapped_count: Enum.count(discovered, &(not &1.mapped)),
      discovered: discovered
    }
  end

  defp parse_macro_params(raw_params) do
    Regex.scan(@param_regex, raw_params)
    |> Enum.map(fn captures ->
      key = Enum.at(captures, 1)
      value = Enum.at(captures, 2) || Enum.at(captures, 3) || Enum.at(captures, 4) || ""
      {key, value}
    end)
    |> Map.new()
  end

  defp serialize_params(params) when params == %{}, do: ""

  defp serialize_params(params) do
    params
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("|")
  end

  defp increment_year(nil, acc), do: acc

  defp increment_year(value, acc) do
    case year_from(value) do
      nil -> acc
      year -> Map.update(acc, year, 1, &(&1 + 1))
    end
  end

  defp year_from(value) when is_integer(value) do
    cond do
      value > 100_000_000_000 ->
        value
        |> DateTime.from_unix!(:millisecond)
        |> DateTime.shift_zone!("Etc/UTC")
        |> Map.get(:year)

      value > 1_000_000_000 ->
        value |> DateTime.from_unix!(:second) |> Map.get(:year)

      true ->
        value
    end
  rescue
    _error in [ArgumentError] -> nil
  end

  defp year_from(value) when is_binary(value) do
    normalized = String.replace(value, " ", "T")

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, naive} ->
        naive.year

      _other ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            datetime.year

          _ ->
            case Regex.run(~r/(\d{4})/, value) do
              [_, year] -> String.to_integer(year)
              _other -> nil
            end
        end
    end
  end

  defp year_from(_value), do: nil

  defp count_status(items, status), do: Enum.count(items, &(&1.status == status))

  defp notify_progress(callback, step, detail \\ nil) when is_function(callback, 2) do
    try do
      callback.(step, detail)
    rescue
      error ->
        Logger.warning(
          "import analysis progress callback failed step=#{inspect(step)}: #{Exception.message(error)}"
        )

        :ok
    end

    :ok
  end

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

end
