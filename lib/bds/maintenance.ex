defmodule BDS.Maintenance do
  @moduledoc false

  def rebuild_from_filesystem(project_id, entity_type) do
    case normalize_entity_type(entity_type) do
      :post -> BDS.Posts.rebuild_posts_from_files(project_id)
      :media -> BDS.Media.rebuild_media_from_files(project_id)
      :script -> BDS.Scripts.rebuild_scripts_from_files(project_id)
      :template -> BDS.Templates.rebuild_templates_from_files(project_id)
      :unsupported -> {:error, :unsupported_entity_type}
    end
  end

  defp normalize_entity_type(:post), do: :post
  defp normalize_entity_type(:media), do: :media
  defp normalize_entity_type(:script), do: :script
  defp normalize_entity_type(:template), do: :template
  defp normalize_entity_type("post"), do: :post
  defp normalize_entity_type("media"), do: :media
  defp normalize_entity_type("script"), do: :script
  defp normalize_entity_type("template"), do: :template
  defp normalize_entity_type(_entity_type), do: :unsupported
end
