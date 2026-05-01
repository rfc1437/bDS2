defmodule BDS.Generation.Renderers do
  @moduledoc false

  alias BDS.Generation.Paths
  alias BDS.Projects
  alias BDS.Rendering

  @doc "Render the home page (HTML) using the project's template engine."
  @spec render_home(map(), String.t() | nil) :: String.t()
  def render_home(plan, language) do
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

  @doc "Render a single post page using the post template (fallback to a tiny inline shell)."
  @spec render_post_page(String.t(), iodata(), String.t(), String.t() | nil) :: String.t()
  def render_post_page(title, body, slug, language) do
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

  @doc "Render an archive page (category, tag, year) with pagination."
  @spec render_archive_page(map(), String.t(), [map()], String.t() | nil, String.t(), map()) ::
          String.t()
  def render_archive_page(plan, title, posts, language, kind, pagination) do
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
        %{
          id: post.id,
          slug: post.slug,
          title: post.title,
          href: "#",
          excerpt: post.excerpt,
          content: nil,
          language: post.language
        }
      end),
      %{kind: kind, name: title},
      pagination,
      fallback
    )
  end

  @doc "Render a date-archive page (year/month/day) with pagination."
  @spec render_date_archive_page(map(), String.t(), map(), [map()], String.t() | nil, map()) ::
          String.t()
  def render_date_archive_page(plan, label, archive_context, posts, language, pagination) do
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
      build_list_posts(plan.base_url, posts, Paths.route_language(plan.language, language)),
      archive_context,
      pagination,
      fallback
    )
  end

  @doc "Try the project's post template; on error, fall back to the inline `fallback` thunk."
  @spec render_post_output(String.t(), String.t() | nil, map(), (-> String.t())) :: String.t()
  def render_post_output(project_id, template_slug, assigns, fallback) do
    case Rendering.render_post_page(project_id, template_slug, assigns) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  @doc "Render a list/archive page through the project template, falling back to inline."
  @spec render_list_output(
          map(),
          String.t() | nil,
          String.t(),
          [map()],
          map(),
          map(),
          (-> String.t())
        ) ::
          String.t()
  def render_list_output(
        %{project_id: project_id, language: main_language},
        language,
        page_title,
        posts,
        archive_context,
        pagination,
        fallback
      )
      when is_binary(project_id) do
    case Rendering.render_list_page(project_id, %{
           language: language,
           language_prefix: Paths.language_prefix(language, main_language),
           page_title: page_title,
           posts: posts,
           archive_context: archive_context,
           pagination: pagination
         }) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  @doc "Render the project's 404 page via its template, falling back to a static page."
  @spec render_not_found_output(map(), String.t() | nil) :: String.t()
  def render_not_found_output(%{project_id: project_id, language: main_language}, language)
      when is_binary(project_id) do
    case Rendering.render_not_found_page(project_id, %{
           language: language,
           language_prefix: Paths.language_prefix(language, main_language)
         }) do
      {:ok, rendered} -> rendered
      {:error, _reason} -> render_not_found_page(language)
    end
  end

  @doc "Static fallback HTML for a 404 page."
  @spec render_not_found_page(String.t() | nil) :: String.t()
  def render_not_found_page(language) do
    [
      "<html><body data-language=\"",
      to_string(language),
      "\"><section data-template=\"not-found\"><h1>404</h1><p>Not Found</p></section></body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Build the list-of-posts payload (with hrefs and bodies) for archive/list templates."
  @spec build_list_posts(String.t() | nil, [map()], String.t() | nil) :: [map()]
  def build_list_posts(base_url, posts, language_prefix) do
    Enum.map(posts, fn post ->
      %{
        id: post.id,
        slug: post.slug,
        title: post.title,
        href: Paths.url_for_output(base_url, Paths.post_output_path(post, language_prefix)),
        excerpt: post.excerpt,
        content: load_body(post.project_id, post.file_path, post.content)
      }
    end)
  end

  @doc "Load the post body from disk (or pass-through inline content) for list rendering."
  @spec load_body(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def load_body(_project_id, _file_path, inline_content) when is_binary(inline_content),
    do: inline_content

  def load_body(project_id, file_path, _inline_content) do
    case file_path do
      nil ->
        ""

      "" ->
        ""

      value ->
        project_path =
          Path.expand(value, Projects.project_data_dir(Projects.get_project!(project_id)))

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
end
