defmodule BDS.Preview.Router do
  @moduledoc false

  import Ecto.Query

  alias BDS.Generation.Paths
  alias BDS.MapUtils
  alias BDS.Metadata, as: ProjectMetadata
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Rendering
  alias BDS.Rendering.TemplateSelection
  alias BDS.Repo

  @type route ::
          {:home, pos_integer()}
          | {:post, String.t(), integer(), integer(), integer()}
          | {:page, String.t()}
          | {:category, String.t(), pos_integer()}
          | {:tag, String.t(), pos_integer()}
          | {:year, integer(), pos_integer()}
          | {:month, integer(), integer(), pos_integer()}
          | {:day, integer(), integer(), integer(), pos_integer()}
          | :not_matched

  @spec render_route(String.t(), String.t()) :: {:ok, map()} | :not_matched
  def render_route(project_id, request_path) do
    {:ok, metadata} = ProjectMetadata.get_project_metadata(project_id)
    main_language = metadata.main_language || "en"
    blog_languages = metadata.blog_languages || []
    additional_languages = Enum.reject(blog_languages, &(&1 == main_language))

    segments = String.split(request_path, "/", trim: true)
    {language, route_segments} = extract_language_prefix(segments, additional_languages)
    effective_language = language || main_language

    case match_route(route_segments) do
      :not_matched ->
        :not_matched

      route ->
        case render(project_id, route, effective_language, main_language, metadata) do
          {:ok, body} ->
            {:ok, %{content_type: "text/html", body: body}}

          {:error, :not_found} ->
            :not_matched
        end
    end
  end

  @spec match_route([String.t()]) :: route()
  def match_route([]), do: {:home, 1}
  def match_route(["page", n]), do: {:home, parse_page(n)}

  def match_route(["category", name]), do: {:category, URI.decode(name), 1}

  def match_route(["category", name, "page", n]),
    do: {:category, URI.decode(name), parse_page(n)}

  def match_route(["tag", name]), do: {:tag, URI.decode(name), 1}
  def match_route(["tag", name, "page", n]), do: {:tag, URI.decode(name), parse_page(n)}

  def match_route([y, m, d, slug]) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d) do
      {:post, slug, year, month, day}
    else
      _ -> :not_matched
    end
  end

  def match_route([y, m, d, "page", n]) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d) do
      {:day, year, month, day, parse_page(n)}
    else
      _ -> :not_matched
    end
  end

  def match_route([y, m, d]) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d) do
      {:day, year, month, day, 1}
    else
      _ -> :not_matched
    end
  end

  def match_route([y, m, "page", n]) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m) do
      {:month, year, month, parse_page(n)}
    else
      _ -> :not_matched
    end
  end

  def match_route([y, m]) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m) do
      {:month, year, month, 1}
    else
      _ -> :not_matched
    end
  end

  def match_route([y, "page", n]) do
    with {year, ""} <- Integer.parse(y) do
      {:year, year, parse_page(n)}
    else
      _ -> :not_matched
    end
  end

  def match_route([y]) do
    case Integer.parse(y) do
      {year, ""} -> {:year, year, 1}
      _ -> {:page, y}
    end
  end

  def match_route(_segments), do: :not_matched

  ## Rendering

  defp render(project_id, {:home, page_number}, language, main_language, metadata) do
    posts = load_published_list_posts(project_id, metadata)
    posts = maybe_resolve_language(posts, language, main_language, project_id)
    render_list(project_id, posts, page_number, metadata, language, main_language, %{kind: "core"})
  end

  defp render(project_id, {:post, slug, year, month, day}, language, main_language, _metadata) do
    case find_post_by_slug_and_date(project_id, slug, year, month, day) do
      nil ->
        {:error, :not_found}

      post ->
        render_post(project_id, post, language, main_language)
    end
  end

  defp render(project_id, {:page, slug}, language, main_language, _metadata) do
    case find_page_by_slug(project_id, slug) do
      nil -> {:error, :not_found}
      post -> render_post(project_id, post, language, main_language)
    end
  end

  defp render(project_id, {:category, name, page_number}, language, main_language, metadata) do
    posts = load_published_posts_by_category(project_id, name)
    posts = maybe_resolve_language(posts, language, main_language, project_id)

    render_list(project_id, posts, page_number, metadata, language, main_language, %{
      kind: "category",
      name: name
    })
  end

  defp render(project_id, {:tag, name, page_number}, language, main_language, metadata) do
    posts = load_published_posts_by_tag(project_id, name)
    posts = maybe_resolve_language(posts, language, main_language, project_id)

    render_list(project_id, posts, page_number, metadata, language, main_language, %{
      kind: "tag",
      name: name
    })
  end

  defp render(project_id, {:year, year, page_number}, language, main_language, metadata) do
    posts = load_published_posts_by_year(project_id, year)
    posts = maybe_resolve_language(posts, language, main_language, project_id)

    render_list(project_id, posts, page_number, metadata, language, main_language, %{
      kind: "date",
      year: year
    })
  end

  defp render(project_id, {:month, year, month, page_number}, language, main_language, metadata) do
    posts = load_published_posts_by_month(project_id, year, month)
    posts = maybe_resolve_language(posts, language, main_language, project_id)

    render_list(project_id, posts, page_number, metadata, language, main_language, %{
      kind: "date",
      year: year,
      month: month
    })
  end

  defp render(project_id, {:day, year, month, day, page_number}, language, main_language, metadata) do
    posts = load_published_posts_by_day(project_id, year, month, day)
    posts = maybe_resolve_language(posts, language, main_language, project_id)

    render_list(project_id, posts, page_number, metadata, language, main_language, %{
      kind: "date",
      year: year,
      month: month,
      day: day
    })
  end

  ## Post rendering

  defp render_post(project_id, post, language, main_language) do
    {effective_record, body} = resolve_post_for_language(project_id, post, language, main_language)

    assigns = %{
      id: effective_record.id,
      title: effective_record.title,
      content: body,
      slug: post.slug,
      language: Map.get(effective_record, :language, post.language),
      excerpt: Map.get(effective_record, :excerpt, post.excerpt),
      _post_record: effective_record
    }

    effective_slug = post.template_slug || TemplateSelection.resolve_post_template_slug(project_id, post.tags, post.categories)

    case Rendering.render_post_page(project_id, effective_slug, assigns) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp resolve_post_for_language(project_id, post, language, main_language) do
    post_lang = String.downcase(to_string(post.language || main_language))
    target_lang = String.downcase(to_string(language))

    if post_lang == target_lang do
      {post, Posts.editor_body(post)}
    else
      case Repo.get_by(Translation,
             translation_for: post.id,
             language: language,
             project_id: project_id
           ) do
        %Translation{status: status} = translation when status in [:published, :draft] ->
          {translation, Posts.editor_body(translation)}

        _ ->
          {post, Posts.editor_body(post)}
      end
    end
  end

  ## List rendering

  defp render_list(project_id, posts, page_number, metadata, language, main_language, archive_ctx) do
    max_per_page = max(metadata.max_posts_per_page || 50, 1)
    total_items = length(posts)
    total_pages = Paths.page_count(total_items, max_per_page)

    if page_number > total_pages and page_number > 1 do
      {:error, :not_found}
    else
      page_posts =
        posts
        |> Enum.chunk_every(max_per_page)
        |> Enum.at(page_number - 1, [])
        |> Enum.map(&post_to_list_entry(project_id, &1, language, main_language))

      language_prefix = Paths.language_prefix(language, main_language)
      route_language = Paths.route_language(main_language, language)

      segments = archive_context_to_segments(archive_ctx)

      pagination = %{
        current_page: page_number,
        total_pages: total_pages,
        total_items: total_items,
        items_per_page: max_per_page,
        has_prev_page: page_number > 1,
        prev_page_href: Paths.archive_or_root_href(route_language, segments, page_number - 1),
        has_next_page: page_number < total_pages,
        next_page_href: Paths.archive_or_root_href(route_language, segments, page_number + 1)
      }

      assigns = %{
        language: language,
        language_prefix: language_prefix,
        page_title: archive_page_title(archive_ctx),
        posts: page_posts,
        archive_context: archive_ctx,
        pagination: pagination
      }

      try do
        case Rendering.render_list_page(project_id, assigns) do
          {:ok, rendered} -> {:ok, rendered}
          {:error, _reason} -> {:ok, fallback_list_html(page_posts, archive_ctx)}
        end
      rescue
        _ -> {:ok, fallback_list_html(page_posts, archive_ctx)}
      end
    end
  end

  defp post_to_list_entry(_project_id, post, language, main_language) do
    route_language = Paths.route_language(main_language, language)

    %{
      id: post.id,
      slug: post.slug,
      title: post.title,
      href: Paths.url_for_output(nil, Paths.post_output_path(post, route_language)),
      excerpt: post.excerpt,
      content: Posts.editor_body(post),
      language: post.language,
      author: post.author,
      created_at: post.created_at,
      updated_at: post.updated_at,
      published_at: post.published_at,
      tags: post.tags || [],
      categories: post.categories || [],
      template_slug: post.template_slug,
      do_not_translate: Map.get(post, :do_not_translate, false)
    }
  end

  defp archive_context_to_segments(%{kind: "core"}), do: []
  defp archive_context_to_segments(%{kind: "category", name: name}), do: ["category", name]
  defp archive_context_to_segments(%{kind: "tag", name: name}), do: ["tag", name]

  defp archive_context_to_segments(%{kind: "date", year: y, month: m, day: d})
       when is_integer(y) and is_integer(m) and is_integer(d) do
    [
      Integer.to_string(y),
      String.pad_leading(Integer.to_string(m), 2, "0"),
      String.pad_leading(Integer.to_string(d), 2, "0")
    ]
  end

  defp archive_context_to_segments(%{kind: "date", year: y, month: m})
       when is_integer(y) and is_integer(m) do
    [Integer.to_string(y), String.pad_leading(Integer.to_string(m), 2, "0")]
  end

  defp archive_context_to_segments(%{kind: "date", year: y}) when is_integer(y),
    do: [Integer.to_string(y)]

  defp archive_context_to_segments(_), do: []

  defp fallback_list_html(posts, archive_ctx) do
    title = archive_page_title(archive_ctx) || "Archive"

    items =
      posts
      |> Enum.map(fn post ->
        ["<li>", to_string(Map.get(post, :title, "")), "</li>"]
      end)
      |> IO.iodata_to_binary()

    IO.iodata_to_binary([
      "<html><body><h1>",
      title,
      "</h1><ul>",
      items,
      "</ul></body></html>"
    ])
  end

  defp archive_page_title(%{kind: "category", name: name}), do: name
  defp archive_page_title(%{kind: "tag", name: name}), do: name

  defp archive_page_title(%{kind: "date", year: y, month: m, day: d})
       when is_integer(y) and is_integer(m) and is_integer(d),
       do: "#{y}-#{String.pad_leading(Integer.to_string(m), 2, "0")}-#{String.pad_leading(Integer.to_string(d), 2, "0")}"

  defp archive_page_title(%{kind: "date", year: y, month: m})
       when is_integer(y) and is_integer(m),
       do: "#{y}-#{String.pad_leading(Integer.to_string(m), 2, "0")}"

  defp archive_page_title(%{kind: "date", year: y}) when is_integer(y), do: Integer.to_string(y)
  defp archive_page_title(_), do: nil

  ## Data loading

  @default_category_settings %{
    "article" => %{render_in_lists: true},
    "picture" => %{render_in_lists: true},
    "aside" => %{render_in_lists: true},
    "page" => %{render_in_lists: false}
  }

  defp load_published_list_posts(project_id, metadata) do
    raw_settings = Map.get(metadata, :category_settings, %{}) || %{}

    resolved =
      Enum.reduce(raw_settings, @default_category_settings, fn {category, settings}, acc ->
        flag =
          case MapUtils.attr(settings, :render_in_lists, true) do
            false -> false
            _ -> true
          end

        Map.put(acc, category, %{render_in_lists: flag})
      end)

    excluded =
      resolved
      |> Enum.filter(fn {_cat, settings} -> settings.render_in_lists == false end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    project_id
    |> load_previewable_posts()
    |> Enum.reject(fn post ->
      Enum.any?(post.categories || [], &MapSet.member?(excluded, &1))
    end)
  end

  defp load_previewable_posts(project_id) do
    Repo.all(
      from p in Post,
        where: p.project_id == ^project_id and p.status in [:published, :draft],
        order_by: [desc: p.created_at, desc: p.published_at, asc: p.slug]
    )
  end

  defp load_published_posts_by_category(project_id, category) do
    project_id
    |> load_previewable_posts()
    |> Enum.filter(fn post -> category in (post.categories || []) end)
  end

  defp load_published_posts_by_tag(project_id, tag) do
    project_id
    |> load_previewable_posts()
    |> Enum.filter(fn post -> tag in (post.tags || []) end)
  end

  defp load_published_posts_by_year(project_id, year) do
    project_id
    |> load_previewable_posts()
    |> Enum.filter(fn post ->
      {post_year, _, _} = Paths.local_date_parts!(post.created_at)
      post_year == year
    end)
  end

  defp load_published_posts_by_month(project_id, year, month) do
    project_id
    |> load_previewable_posts()
    |> Enum.filter(fn post ->
      {post_year, post_month, _} = Paths.local_date_parts!(post.created_at)
      post_year == year and post_month == month
    end)
  end

  defp load_published_posts_by_day(project_id, year, month, day) do
    project_id
    |> load_previewable_posts()
    |> Enum.filter(fn post ->
      {post_year, post_month, post_day} = Paths.local_date_parts!(post.created_at)
      post_year == year and post_month == month and post_day == day
    end)
  end

  defp find_post_by_slug_and_date(project_id, slug, year, month, day) do
    case Repo.one(
           from p in Post,
             where:
               p.project_id == ^project_id and p.slug == ^slug and
                 p.status in [:published, :draft]
         ) do
      nil ->
        nil

      post ->
        {post_year, post_month, post_day} = Paths.local_date_parts!(post.created_at)

        if post_year == year and post_month == month and post_day == day do
          post
        else
          nil
        end
    end
  end

  defp find_page_by_slug(project_id, slug) do
    case Repo.one(
           from p in Post,
             where:
               p.project_id == ^project_id and p.slug == ^slug and
                 p.status in [:published, :draft]
         ) do
      %Post{categories: categories} = post ->
        if "page" in (categories || []), do: post, else: nil

      nil ->
        nil
    end
  end

  ## Language resolution

  defp maybe_resolve_language(posts, language, main_language, project_id) do
    if String.downcase(to_string(language)) == String.downcase(to_string(main_language)) do
      posts
    else
      translations = load_translations_for_language(project_id, Enum.map(posts, & &1.id), language)

      Enum.map(posts, fn post ->
        case Map.get(translations, post.id) do
          nil -> post
          translation -> overlay_translation(post, translation)
        end
      end)
    end
  end

  defp load_translations_for_language(project_id, post_ids, language) do
    if Enum.empty?(post_ids) do
      %{}
    else
      Repo.all(
        from t in Translation,
          where:
            t.project_id == ^project_id and
              t.translation_for in ^post_ids and
              t.language == ^language and
              t.status in [:published, :draft]
      )
      |> Map.new(&{&1.translation_for, &1})
    end
  end

  defp overlay_translation(post, translation) do
    %{
      post
      | id: translation.id,
        title: translation.title,
        excerpt: translation.excerpt,
        content: translation.content,
        language: translation.language,
        updated_at: translation.updated_at,
        published_at: translation.published_at || post.published_at
    }
  end

  ## Helpers

  defp extract_language_prefix([], _additional_languages), do: {nil, []}

  defp extract_language_prefix([first | rest] = segments, additional_languages) do
    normalized = String.downcase(first)

    if normalized in Enum.map(additional_languages, &String.downcase/1) do
      {normalized, rest}
    else
      {nil, segments}
    end
  end

  defp parse_page(n) do
    case Integer.parse(n) do
      {page, ""} when page >= 1 -> page
      _ -> 1
    end
  end
end
