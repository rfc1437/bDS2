defmodule BDS.Generation do
  @moduledoc false

  import Ecto.Query

  alias BDS.Generation.GeneratedFileHash
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Rendering
  alias BDS.Repo
  alias BDS.Slug

  @core_sections [:core, :single, :category, :tag, :date]

  def plan_generation(project_id, sections \\ [:core]) when is_binary(project_id) and is_list(sections) do
    project = Projects.get_project!(project_id)
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    {:ok, generated_files} = list_generated_files(project_id)

    {:ok,
     %{
       project_id: project_id,
       project_name: project.name,
       base_url: normalize_base_url(metadata.public_url),
       language: metadata.main_language,
       blog_languages: normalize_blog_languages(metadata.main_language, metadata.blog_languages),
       max_posts_per_page: metadata.max_posts_per_page,
      categories: metadata.categories,
       pico_theme: metadata.pico_theme,
       sections: normalize_sections(sections),
       generated_files: generated_files
     }}
  end

  def generate_site(project_id, sections \\ [:core]) when is_binary(project_id) and is_list(sections) do
    with {:ok, plan} <- plan_generation(project_id, sections) do
      outputs = build_outputs(plan)

      Enum.each(outputs, fn {relative_path, content} ->
        {:ok, _write} = write_generated_file(project_id, relative_path, content)
      end)

      {:ok, generated_files} = list_generated_files(project_id)
      {:ok, %{sections: plan.sections, generated_files: generated_files}}
    end
  end

  def post_output_path(%Post{} = post), do: post_output_path(post, nil)

  def post_output_path(%Post{} = post, language) do
    datetime = DateTime.from_unix!(post.created_at)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = datetime.day |> Integer.to_string() |> String.pad_leading(2, "0")

    path_parts = [year, month, day, post.slug, "index.html"]

    case language do
      nil -> Path.join(path_parts)
      "" -> Path.join(path_parts)
      value -> Path.join([value | path_parts])
    end
  end

  def write_generated_file(project_id, relative_path, content)
      when is_binary(project_id) and is_binary(relative_path) and is_binary(content) do
    project = Projects.get_project!(project_id)
    content_hash = sha256(content)
    now = System.system_time(:second)

    case Repo.get_by(GeneratedFileHash, project_id: project_id, relative_path: relative_path) do
      %GeneratedFileHash{content_hash: ^content_hash} ->
        {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: false}}

      _existing ->
        full_path = output_path(project, relative_path)
        :ok = File.mkdir_p(Path.dirname(full_path))
        :ok = File.write(full_path, content)

        attrs = %{
          project_id: project_id,
          relative_path: relative_path,
          content_hash: content_hash,
          updated_at: now
        }

        %GeneratedFileHash{}
        |> GeneratedFileHash.changeset(attrs)
        |> Repo.insert!(
          on_conflict: [set: [content_hash: content_hash, updated_at: now]],
          conflict_target: [:project_id, :relative_path]
        )

        {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: true}}
    end
  end

  def list_generated_files(project_id) when is_binary(project_id) do
    {:ok,
     Repo.all(
       from generated_file in GeneratedFileHash,
         where: generated_file.project_id == ^project_id,
         order_by: [asc: generated_file.relative_path]
     )}
  end

  def delete_generated_file(project_id, relative_path) when is_binary(project_id) and is_binary(relative_path) do
    project = Projects.get_project!(project_id)

    case File.rm(output_path(project, relative_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end

    Repo.delete_all(
      from generated_file in GeneratedFileHash,
        where: generated_file.project_id == ^project_id and generated_file.relative_path == ^relative_path
    )

    :ok
  end

  defp build_outputs(plan) do
    published_posts = list_published_posts(plan.project_id)
    published_translations = list_published_translations(plan.project_id)
    post_by_id = Map.new(published_posts, &{&1.id, &1})

    core_outputs =
      if :core in plan.sections do
        build_core_outputs(plan, published_posts)
      else
        []
      end

    single_outputs =
      if :single in plan.sections do
        build_single_outputs(plan.project_id, published_posts, published_translations, post_by_id)
      else
        []
      end

    archive_outputs =
      build_archive_outputs(plan, published_posts)

    urls =
      core_outputs ++ single_outputs ++ archive_outputs
      |> Enum.map(fn {relative_path, _content} -> url_for_output(plan.base_url, relative_path) end)

    sitemap =
      if :core in plan.sections do
        [{"sitemap.xml", render_sitemap(urls)}]
      else
        []
      end

    core_outputs ++ single_outputs ++ archive_outputs ++ sitemap
  end

  defp build_archive_outputs(plan, published_posts) do
    languages = plan.blog_languages

    category_outputs =
      if :category in plan.sections do
        build_category_outputs(plan, published_posts, languages)
      else
        []
      end

    tag_outputs =
      if :tag in plan.sections do
        build_tag_outputs(plan, published_posts, languages)
      else
        []
      end

    date_outputs =
      if :date in plan.sections do
        build_date_outputs(plan, published_posts, languages)
      else
        []
      end

    category_outputs ++ tag_outputs ++ date_outputs
  end

  defp build_category_outputs(plan, published_posts, languages) do
    category_posts =
      published_posts
      |> Enum.flat_map(fn post -> Enum.map(post.categories || [], &{&1, post}) end)
      |> Enum.group_by(fn {category, _post} -> category end, fn {_category, post} -> post end)

    Enum.flat_map(category_posts, fn {category, posts} ->
      paginated_posts = Enum.chunk_every(posts, max(plan.max_posts_per_page, 1))
      category_slug = Slug.slugify(category)

      Enum.with_index(paginated_posts, 1)
      |> Enum.flat_map(fn {page_posts, page_number} ->
        Enum.map(languages, fn language ->
          {
            archive_path(route_language(plan.language, language), ["category", category_slug], page_number),
            render_archive_page(plan, category, page_posts, language, "category")
          }
        end)
      end)
    end)
  end

  defp build_tag_outputs(plan, published_posts, languages) do
    tag_posts =
      published_posts
      |> Enum.flat_map(fn post -> Enum.map(post.tags || [], &{&1, post}) end)
      |> Enum.group_by(fn {tag, _post} -> tag end, fn {_tag, post} -> post end)

    Enum.flat_map(tag_posts, fn {tag, posts} ->
      tag_slug = Slug.slugify(tag)

      Enum.map(languages, fn language ->
        {
          archive_path(route_language(plan.language, language), ["tag", tag_slug], 1),
          render_archive_page(plan, tag, posts, language, "tag")
        }
      end)
    end)
  end

  defp build_date_outputs(plan, published_posts, languages) do
    years = Enum.group_by(published_posts, &year_key(&1.created_at))
    months = Enum.group_by(published_posts, &month_key(&1.created_at))

    year_outputs =
      Enum.flat_map(years, fn {year, posts} ->
        Enum.map(languages, fn language ->
          {
            archive_path(route_language(plan.language, language), [year], 1),
            render_date_archive_page(plan, year, posts, language)
          }
        end)
      end)

    month_outputs =
      Enum.flat_map(months, fn {{year, month}, posts} ->
        Enum.map(languages, fn language ->
          {
            archive_path(route_language(plan.language, language), [year, month], 1),
            render_date_archive_page(plan, "#{year}-#{month}", posts, language)
          }
        end)
      end)

    year_outputs ++ month_outputs
  end

  defp build_core_outputs(plan, published_posts) do
    language = plan.language
    additional_languages = Enum.reject(plan.blog_languages, &(&1 == language))
    main_posts = build_list_posts(plan.base_url, published_posts, nil)

    [
      {"index.html", render_list_output(plan, language, plan.project_name, main_posts, %{kind: "core"}, fn -> render_home(plan, language) end)},
      {"404.html", render_not_found_output(plan, language)},
      {"feed.xml", render_feed(plan, language, published_posts)},
      {"atom.xml", render_atom(plan, language, published_posts)},
      {"calendar.json", render_calendar(published_posts)}
    ] ++
      Enum.flat_map(additional_languages, fn localized_language ->
        localized_prefix = route_language(plan.language, localized_language)
        localized_posts = build_list_posts(plan.base_url, published_posts, localized_prefix)

        [
          {Path.join(localized_language, "index.html"), render_list_output(plan, localized_language, plan.project_name, localized_posts, %{kind: "core"}, fn -> render_home(plan, localized_language) end)},
          {Path.join(localized_language, "404.html"), render_not_found_output(plan, localized_language)},
          {Path.join(localized_language, "feed.xml"), render_feed(plan, localized_language, published_posts)},
          {Path.join(localized_language, "atom.xml"), render_atom(plan, localized_language, published_posts)}
        ]
      end)
  end

  defp build_single_outputs(project_id, published_posts, published_translations, post_by_id) do
    post_outputs =
      Enum.map(published_posts, fn post ->
        body = load_body(project_id, post.file_path, post.content)

        {post_output_path(post),
         render_post_output(project_id, post.template_slug, %{id: post.id, title: post.title, content: body, slug: post.slug, language: post.language, excerpt: post.excerpt}, fn ->
           render_post_page(post.title, body, post.slug, post.language)
         end)}
      end)

    translation_outputs =
      Enum.flat_map(published_translations, fn translation ->
        case post_by_id[translation.translation_for] do
          nil ->
            []

          post ->
            body = load_body(project_id, translation.file_path, translation.content)

            [
              {post_output_path(post, translation.language),
               render_post_output(project_id, post.template_slug, %{id: translation.id, title: translation.title, content: body, slug: post.slug, language: translation.language, excerpt: translation.excerpt}, fn ->
                 render_post_page(translation.title, body, post.slug, translation.language)
               end)}
            ]
        end
      end)

    post_outputs ++ translation_outputs
  end

  defp list_published_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id and post.status == :published,
        order_by: [asc: post.created_at, asc: post.slug]
    )
  end

  defp list_published_translations(project_id) do
    Repo.all(
      from translation in Translation,
        where: translation.project_id == ^project_id and translation.status == :published,
        order_by: [asc: translation.created_at, asc: translation.language]
    )
  end

  defp normalize_sections(sections) do
    sections
    |> Enum.filter(&(&1 in @core_sections))
    |> Enum.uniq()
    |> case do
      [] -> [:core]
      values -> values
    end
  end

  defp archive_path(language, segments, 1), do: archive_path(language, segments)

  defp archive_path(language, segments, page_number) do
    archive_path(language, segments ++ ["page", Integer.to_string(page_number)])
  end

  defp archive_path(nil, segments), do: Path.join(segments ++ ["index.html"])
  defp archive_path("", segments), do: Path.join(segments ++ ["index.html"])

  defp archive_path(language, segments) do
    prefix = if language in [nil, ""], do: [], else: [language]
    Path.join(prefix ++ segments ++ ["index.html"])
  end

  defp normalize_base_url(nil), do: nil
  defp normalize_base_url(url), do: String.trim_trailing(url, "/")

  defp normalize_blog_languages(main_language, blog_languages) do
    ([main_language] ++ (blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp route_language(main_language, language) when main_language == language, do: nil
  defp route_language(_main_language, language), do: language

  defp render_home(plan, language) do
    [
      "<html>",
      "<head><title>",
      plan.project_name,
      "</title></head>",
      "<body data-language=\"",
      to_string(language),
      "\"><main><h1>",
      plan.project_name,
      "</h1></main></body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_feed(plan, language, published_posts) do
    items =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<item><title>#{xml_escape(post.title)}</title><link>#{url_for_output(plan.base_url, post_output_path(post))}</link></item>"
      end)
      |> Enum.join()

    "<rss><channel><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{items}</channel></rss>"
  end

  defp render_atom(plan, language, published_posts) do
    entries =
      published_posts
      |> Enum.filter(&(&1.language == language or language == plan.language))
      |> Enum.map(fn post ->
        "<entry><title>#{xml_escape(post.title)}</title><id>#{url_for_output(plan.base_url, post_output_path(post))}</id></entry>"
      end)
      |> Enum.join()

    "<feed><title>#{xml_escape(plan.project_name)} (#{xml_escape(language || "default")})</title>#{entries}</feed>"
  end

  defp render_calendar(published_posts) do
    published_posts
    |> Enum.map(fn post ->
      datetime = DateTime.from_unix!(post.created_at)
      %{date: Date.to_iso8601(DateTime.to_date(datetime)), slug: post.slug, title: post.title}
    end)
    |> Jason.encode!()
  end

  defp render_sitemap(urls) do
    entries = Enum.map_join(urls, "", fn url -> "<url><loc>#{xml_escape(url)}</loc></url>" end)
    "<urlset>#{entries}</urlset>"
  end

  defp render_post_page(title, body, slug, language) do
    [
      "<html>",
      "<head><title>",
      to_string(title),
      "</title></head>",
      "<body data-slug=\"",
      to_string(slug),
      "\" data-language=\"",
      to_string(language),
      "\"><article data-pagefind-body>",
      body,
      "</article></body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_archive_page(plan, title, posts, language, kind) do
    fallback = fn ->
      items =
        posts
        |> Enum.map(fn post -> ["<li>", post.title, "</li>"] end)
        |> IO.iodata_to_binary()

      [
        "<html><body data-kind=\"",
        kind,
        "\" data-language=\"",
        to_string(language),
        "\"><h1>",
        title,
        "</h1><ul>",
        items,
        "</ul></body></html>"
      ]
      |> IO.iodata_to_binary()
    end

    render_list_output(
      plan,
      language,
      title,
      Enum.map(posts, fn post ->
        %{title: post.title, href: "#", excerpt: post.excerpt, content: nil}
      end),
      %{kind: kind, name: title},
      fallback
    )
  end

  defp render_date_archive_page(plan, label, posts, language) do
    fallback = fn ->
      items =
        posts
        |> Enum.map(fn post -> ["<li>", post.title, "</li>"] end)
        |> IO.iodata_to_binary()

      [
        "<html><body data-kind=\"date\" data-language=\"",
        to_string(language),
        "\"><h1>",
        label,
        "</h1><ul>",
        items,
        "</ul></body></html>"
      ]
      |> IO.iodata_to_binary()
    end

    render_list_output(
      plan,
      language,
      label,
      Enum.map(posts, fn post ->
        %{title: post.title, href: "#", excerpt: post.excerpt, content: nil}
      end),
      %{kind: "date", name: label},
      fallback
    )
  end

  defp load_body(_project_id, _file_path, inline_content) when is_binary(inline_content), do: inline_content

  defp load_body(project_id, file_path, _inline_content) do
    case file_path do
      nil -> ""
      "" -> ""
      value ->
        project_path = Path.expand(value, Projects.project_data_dir(Projects.get_project!(project_id)))
        case File.read(project_path) do
          {:ok, contents} -> parse_frontmatter_body(contents)
          {:error, _reason} -> ""
        end
    end
  end

  defp parse_frontmatter_body(contents) do
    case String.split(contents, "\n---\n", parts: 2) do
      [_frontmatter, body] -> String.trim_trailing(body, "\n")
      _parts -> contents
    end
  end

  defp year_key(created_at) do
    created_at
    |> DateTime.from_unix!()
    |> Map.fetch!(:year)
    |> Integer.to_string()
  end

  defp month_key(created_at) do
    datetime = DateTime.from_unix!(created_at)
    {Integer.to_string(datetime.year), Integer.to_string(datetime.month) |> String.pad_leading(2, "0")}
  end

  defp build_list_posts(base_url, posts, language_prefix) do
    Enum.map(posts, fn post ->
      %{
        id: post.id,
        slug: post.slug,
        title: post.title,
        href: url_for_output(base_url, post_output_path(post, language_prefix)),
        excerpt: post.excerpt,
        content: load_body(post.project_id, post.file_path, post.content)
      }
    end)
  end

  defp render_post_output(project_id, template_slug, assigns, fallback) do
    case Rendering.render_post_page(project_id, template_slug, assigns) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  defp render_list_output(%{project_id: project_id, language: main_language}, language, page_title, posts, archive_context, fallback)
       when is_binary(project_id) do
    case Rendering.render_list_page(project_id, %{
           language: language,
           language_prefix: language_prefix(language, main_language),
           page_title: page_title,
           posts: posts,
           archive_context: archive_context
         }) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  defp render_list_output(_plan, _language, _page_title, _posts, _archive_context, fallback), do: fallback.()

  defp render_not_found_output(%{project_id: project_id, language: main_language}, language)
       when is_binary(project_id) do
    case Rendering.render_not_found_page(project_id, %{language: language, language_prefix: language_prefix(language, main_language)}) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> render_not_found_page(language)
    end
  end

  defp render_not_found_output(_plan, language), do: render_not_found_page(language)

  defp language_prefix(language, main_language) when language == main_language, do: ""
  defp language_prefix(nil, _main_language), do: ""
  defp language_prefix(language, _main_language), do: "/#{language}"

  defp url_for_output(nil, relative_path), do: "/" <> String.trim_leading(relative_path, "/")

  defp url_for_output(base_url, relative_path) do
    cleaned = relative_path |> String.trim_leading("/") |> String.trim_trailing("index.html")
    suffix = if cleaned == "", do: "/", else: "/" <> cleaned
    String.trim_trailing(base_url, "/") <> suffix
  end

  defp render_not_found_page(language) do
    [
      "<html><body data-language=\"",
      to_string(language),
      "\"><section data-template=\"not-found\"><h1>404</h1><p>Not Found</p></section></body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp output_path(project, relative_path) do
    Path.join([Projects.project_data_dir(project), "html", relative_path])
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
