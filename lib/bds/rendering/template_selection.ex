defmodule BDS.Rendering.TemplateSelection do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Metadata
  alias BDS.Projects
  alias BDS.Rendering.FileSystem
  alias BDS.Rendering.Filters
  alias BDS.Rendering.RenderContext
  alias BDS.Repo
  alias BDS.StarterTemplates
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  @spec resolve_post_template_slug(RenderContext.t() | String.t(), [String.t()], [String.t()]) ::
          String.t() | nil
  def resolve_post_template_slug(%RenderContext{} = ctx, tag_names, category_names) do
    Enum.find_value(tag_names, &Map.get(ctx.tag_template_slug_by_name, &1)) ||
      resolve_from_category_settings(ctx.metadata.category_settings || %{}, category_names)
  end

  def resolve_post_template_slug(project_id, tag_names, category_names) do
    resolve_from_tags(project_id, tag_names) ||
      resolve_from_categories(project_id, category_names)
  end

  defp resolve_from_tags(_project_id, []), do: nil

  defp resolve_from_tags(project_id, tag_names) do
    Repo.all(
      from tag in Tag,
        where:
          tag.project_id == ^project_id and
            tag.name in ^tag_names and
            not is_nil(tag.post_template_slug) and
            tag.post_template_slug != "",
        select: tag.post_template_slug,
        limit: 1
    )
    |> List.first()
  end

  defp resolve_from_categories(_project_id, []), do: nil

  defp resolve_from_categories(project_id, category_names) do
    {:ok, state} = Metadata.get_project_metadata(project_id)
    resolve_from_category_settings(state.category_settings || %{}, category_names)
  end

  defp resolve_from_category_settings(_settings, []), do: nil

  defp resolve_from_category_settings(settings, category_names) do
    Enum.find_value(category_names, fn cat_name ->
      case Map.get(settings, cat_name) do
        %{"post_template_slug" => slug} when is_binary(slug) and slug != "" -> slug
        _ -> nil
      end
    end)
  end

  @spec load_template_source(RenderContext.t() | String.t(), atom(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def load_template_source(%RenderContext{} = ctx, kind, slug) do
    RenderContext.memoize(ctx, {:template_source, kind, slug}, fn ->
      do_load_template_source(ctx.project, ctx.project_id, kind, slug)
    end)
  end

  def load_template_source(project_id, kind, slug) when is_binary(project_id) do
    do_load_template_source(Projects.get_project!(project_id), project_id, kind, slug)
  end

  defp do_load_template_source(project, project_id, kind, slug) do
    case select_template(project_id, kind, slug) do
      %Template{} = template ->
        case published_template_body(project, template) do
          {:ok, _source} = ok ->
            ok

          {:error, reason} = error ->
            maybe_load_bundled_template_source(project, kind, slug, template, reason, error)
        end

      nil ->
        load_bundled_template_source(project, kind, slug)
    end
  end

  defp select_template(project_id, kind, slug) do
    project_id
    |> published_template_query(kind)
    |> select_template_scope(kind, slug)
    |> Repo.one()
  end

  defp published_template_query(project_id, kind) do
    from template in Template,
      where:
        template.project_id == ^project_id and template.kind == ^kind and
          template.status == :published and
          template.enabled == true
  end

  defp select_template_scope(query, _kind, slug) when is_binary(slug) and slug != "" do
    from template in query,
      where: template.slug == ^slug,
      limit: 1
  end

  defp select_template_scope(query, :post, nil) do
    default_slug = StarterTemplates.default_slug(:post)

    from template in query,
      where: template.slug == ^default_slug,
      limit: 1
  end

  defp select_template_scope(query, _kind, nil) do
    from template in query,
      order_by: [desc: template.created_at, desc: template.slug],
      limit: 1
  end

  defp published_template_body(_project, %Template{content: content}) when is_binary(content),
    do: {:ok, content}

  defp published_template_body(project, %Template{} = template) do
    full_path = Path.join(Projects.project_data_dir(project), template.file_path)

    case File.read(full_path) do
      {:ok, contents} ->
        case Frontmatter.parse_document(contents) do
          {:ok, %{body: body}} -> {:ok, body}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec render_template(RenderContext.t() | String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def render_template(%RenderContext{} = ctx, source, assigns) do
    parse_result =
      RenderContext.memoize(ctx, {:template_ast, :erlang.md5(source)}, fn ->
        Liquex.parse(source, BDS.Rendering.LiquidParser)
      end)

    with {:ok, template_ast} <- parse_result,
         {:ok, _rendered} = ok <- safe_liquex_render(template_ast, ctx.file_system, assigns) do
      ok
    else
      {:error, reason, line} when is_integer(line) -> {:error, "#{reason} at line #{line}"}
      {:error, _message} = error -> error
    end
  end

  def render_template(project_id, source, assigns) when is_binary(project_id) do
    project = Projects.get_project!(project_id)
    file_system = FileSystem.new(StarterTemplates.template_roots(project))

    with {:ok, template_ast} <- Liquex.parse(source, BDS.Rendering.LiquidParser),
         {:ok, _rendered} = ok <- safe_liquex_render(template_ast, file_system, assigns) do
      ok
    else
      {:error, reason, line} when is_integer(line) -> {:error, "#{reason} at line #{line}"}
      {:error, _message} = error -> error
    end
  end

  defp safe_liquex_render(template_ast, file_system, assigns) do
    context =
      Liquex.Context.new(assigns,
        static_environment: assigns,
        filter_module: Filters,
        file_system: file_system
      )

    {result, _context} = Liquex.render!(template_ast, context)
    {:ok, IO.iodata_to_binary(result)}
  rescue
    e in Liquex.Error -> {:error, e.message}
  end

  defp load_bundled_template_source(project, kind, slug) do
    desired_slug = bundled_template_slug(kind, slug)

    with true <- is_binary(desired_slug),
         file_system = project |> StarterTemplates.template_roots() |> FileSystem.new(),
         {:ok, source} <- FileSystem.try_read(file_system, desired_slug) do
      case Frontmatter.parse_document(source) do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, :invalid_frontmatter} -> {:ok, source}
      end
    else
      false -> {:error, :template_not_found}
      {:error, :enoent} -> {:error, :template_not_found}
    end
  end

  defp maybe_load_bundled_template_source(project, kind, slug, template, reason, error)
       when reason in [:enoent, :template_not_found] do
    if template.content in [nil, ""] and StarterTemplates.default_template?(kind, template.slug) do
      load_bundled_template_source(project, kind, slug)
    else
      error
    end
  end

  defp maybe_load_bundled_template_source(_project, _kind, _slug, _template, _reason, error),
    do: error

  defp bundled_template_slug(_kind, slug) when is_binary(slug) and slug != "", do: slug
  defp bundled_template_slug(kind, _slug), do: StarterTemplates.default_slug(kind)

  @spec template_render_context(RenderContext.t() | String.t()) :: Liquex.Context.t()
  def template_render_context(%RenderContext{template_context: template_context}),
    do: template_context

  def template_render_context(project_id) do
    project = Projects.get_project!(project_id)

    Liquex.Context.new(%{},
      static_environment: %{},
      filter_module: Filters,
      file_system: FileSystem.new(StarterTemplates.template_roots(project))
    )
  end
end
