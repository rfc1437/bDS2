defmodule BDS.Rendering do
  @moduledoc false

  alias BDS.Rendering.ListArchive
  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.RenderContext
  alias BDS.Rendering.TemplateSelection

  def render_post_page(project_id, template_slug, assigns)
      when is_binary(project_id) and is_map(assigns) do
    render_post_page(RenderContext.build(project_id), template_slug, assigns)
  end

  def render_post_page(%RenderContext{} = ctx, template_slug, assigns) when is_map(assigns) do
    with {:ok, template_source} <-
           TemplateSelection.load_template_source(ctx, :post, template_slug),
         {:ok, rendered} <-
           TemplateSelection.render_template(
             ctx,
             template_source,
             PostRendering.post_assigns(ctx, assigns)
           ) do
      {:ok, rendered}
    end
  end

  def render_list_page(project_id, assigns) when is_binary(project_id) and is_map(assigns) do
    render_list_page(RenderContext.build(project_id), assigns)
  end

  def render_list_page(%RenderContext{} = ctx, assigns) when is_map(assigns) do
    with {:ok, template_source} <- TemplateSelection.load_template_source(ctx, :list, nil),
         {:ok, rendered} <-
           TemplateSelection.render_template(
             ctx,
             template_source,
             ListArchive.list_assigns(ctx, assigns)
           ) do
      {:ok, rendered}
    end
  end

  def render_not_found_page(ctx_or_project_id, assigns \\ %{})

  def render_not_found_page(project_id, assigns)
      when is_binary(project_id) and is_map(assigns) do
    render_not_found_page(RenderContext.build(project_id), assigns)
  end

  def render_not_found_page(%RenderContext{} = ctx, assigns) when is_map(assigns) do
    with {:ok, template_source} <-
           TemplateSelection.load_template_source(ctx, :not_found, nil),
         {:ok, rendered} <-
           TemplateSelection.render_template(
             ctx,
             template_source,
             ListArchive.not_found_assigns(ctx, assigns)
           ) do
      {:ok, rendered}
    end
  end
end
