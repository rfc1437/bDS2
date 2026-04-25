defmodule BDS.StarterTemplates do
  @moduledoc false

  alias BDS.Projects

  def root_path do
    Path.join(Application.app_dir(:bds, "priv/starter_templates"), "templates")
  end

  def template_roots(project) do
    [Path.join(Projects.project_data_dir(project), "templates"), root_path()]
  end

  def default_slug(:post), do: "single-post"
  def default_slug(:list), do: "post-list"
  def default_slug(:not_found), do: "not-found"
  def default_slug(_kind), do: nil

  def default_template?(kind, slug) when is_binary(slug) do
    default_slug(kind) == slug
  end
end
