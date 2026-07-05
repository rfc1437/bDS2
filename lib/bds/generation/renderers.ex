defmodule BDS.Generation.Renderers do
  @moduledoc false

  alias BDS.Generation.Paths
  alias BDS.Projects
  alias BDS.Rendering
  alias BDS.Rendering.RenderContext

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

  @doc "Render an archive page (category, tag) with pagination."
  @spec render_archive_page(map(), String.t(), [map()], String.t() | nil, String.t(), map()) ::
          String.t()
  def render_archive_page(plan, title, posts, language, kind, pagination) do
    render_archive_list_page(
      plan,
      title,
      %{kind: kind, name: title},
      posts,
      language,
      kind,
      pagination
    )
  end

  @doc "Render a date-archive page (year/month/day) with pagination."
  @spec render_date_archive_page(map(), String.t(), map(), [map()], String.t() | nil, map()) ::
          String.t()
  def render_date_archive_page(plan, label, archive_context, posts, language, pagination) do
    render_archive_list_page(plan, label, archive_context, posts, language, "date", pagination)
  end

  # Shared by every archive kind so category/tag pages get the same post
  # payloads (loaded bodies, real hrefs) as date archives.
  defp render_archive_list_page(plan, title, archive_context, posts, language, kind, pagination) do
    fallback = fn -> render_inline_list_page(title, posts, language, kind) end

    render_list_output(
      plan,
      language,
      title,
      build_list_posts(plan, posts, Paths.route_language(plan.language, language)),
      archive_context,
      pagination,
      fallback
    )
  end

  @doc "Try the project's post template; on error, fall back to the inline `fallback` thunk."
  @spec render_post_output(RenderContext.t() | String.t(), String.t() | nil, map(), (-> String.t())) ::
          String.t()
  def render_post_output(render_target, template_slug, assigns, fallback) do
    render_with_fallback(
      fn -> Rendering.render_post_page(render_target, template_slug, assigns) end,
      fallback
    )
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
        %{project_id: project_id, language: main_language} = plan,
        language,
        page_title,
        posts,
        archive_context,
        pagination,
        fallback
      )
      when is_binary(project_id) do
    render_with_fallback(
      fn ->
        Rendering.render_list_page(plan_render_target(plan), %{
          language: language,
          language_prefix: Paths.language_prefix(language, main_language),
          page_title: page_title,
          posts: posts,
          archive_context: archive_context,
          pagination: pagination
        })
      end,
      fallback
    )
  end

  @doc "Render the project's 404 page via its template, falling back to a static page."
  @spec render_not_found_output(map(), String.t() | nil) :: String.t()
  def render_not_found_output(
        %{project_id: project_id, language: main_language} = plan,
        language
      )
      when is_binary(project_id) do
    render_with_fallback(
      fn ->
        Rendering.render_not_found_page(plan_render_target(plan), %{
          language: language,
          language_prefix: Paths.language_prefix(language, main_language)
        })
      end,
      fn -> render_not_found_page(language) end
    )
  end

  @doc "The render context stashed in the plan, or the bare project id when absent."
  @spec plan_render_target(map()) :: RenderContext.t() | String.t()
  def plan_render_target(plan) do
    case Map.get(plan, :render_context) do
      %RenderContext{} = ctx -> ctx
      _other -> plan.project_id
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
  @spec build_list_posts(map(), [map()], String.t() | nil) :: [map()]
  def build_list_posts(plan, posts, language_prefix) do
    render_target = plan_render_target(plan)

    Enum.map(posts, fn post ->
      %{
        id: post.id,
        slug: post.slug,
        title: post.title,
        href: Paths.url_for_output(plan.base_url, Paths.post_output_path(post, language_prefix)),
        excerpt: post.excerpt,
        content: load_body(render_target, post.file_path, post.content)
      }
    end)
  end

  @doc "Load the post body from disk (or pass-through inline content) for list rendering."
  @spec load_body(RenderContext.t() | String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def load_body(_render_target, _file_path, inline_content) when is_binary(inline_content),
    do: inline_content

  def load_body(%RenderContext{} = ctx, file_path, _inline_content)
      when is_binary(file_path) and file_path != "" do
    RenderContext.memoize(ctx, {:post_body, file_path}, fn ->
      read_body_file(Path.expand(file_path, ctx.project_data_dir))
    end)
  end

  def load_body(project_id, file_path, _inline_content)
      when is_binary(project_id) and is_binary(file_path) and file_path != "" do
    project_id
    |> Projects.get_project!()
    |> Projects.project_data_dir()
    |> then(&read_body_file(Path.expand(file_path, &1)))
  end

  def load_body(_render_target, _file_path, _inline_content), do: ""

  defp read_body_file(full_path) do
    case File.read(full_path) do
      {:ok, contents} -> parse_frontmatter_body(contents)
      {:error, _reason} -> ""
    end
  end

  defp render_with_fallback(render_fun, fallback) do
    case render_fun.() do
      {:ok, rendered} -> rendered
      {:error, _reason} -> fallback.()
    end
  end

  defp render_inline_list_page(title, posts, language, kind) do
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

  defp parse_frontmatter_body(contents) do
    case String.split(contents, "\n---\n", parts: 2) do
      [_frontmatter, body] -> String.trim_trailing(body, "\n")
      _parts -> contents
    end
  end
end
