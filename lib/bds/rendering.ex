defmodule BDS.Rendering do
  @moduledoc false

  alias BDS.Rendering.ListArchive
  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.TemplateSelection

  def render_post_page(project_id, template_slug, assigns)
      when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- TemplateSelection.load_template_source(project_id, :post, template_slug),
         {:ok, rendered} <-
           TemplateSelection.render_template(project_id, template_source, PostRendering.post_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_list_page(project_id, assigns) when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- TemplateSelection.load_template_source(project_id, :list, nil),
         {:ok, rendered} <-
           TemplateSelection.render_template(project_id, template_source, ListArchive.list_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end

  def render_not_found_page(project_id, assigns \\ %{})
      when is_binary(project_id) and is_map(assigns) do
    with {:ok, template_source} <- TemplateSelection.load_template_source(project_id, :not_found, nil),
         {:ok, rendered} <-
           TemplateSelection.render_template(project_id, template_source, ListArchive.not_found_assigns(project_id, assigns)) do
      {:ok, rendered}
    end
  end
end
