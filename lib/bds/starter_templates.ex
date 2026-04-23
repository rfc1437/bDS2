defmodule BDS.StarterTemplates do
  @moduledoc false

  alias BDS.Frontmatter
  alias BDS.Projects

  @top_level_templates [
    %{file_name: "single-post.liquid", slug: "single-post", title: "Single Post", kind: :post},
    %{file_name: "post-list.liquid", slug: "post-list", title: "Post List", kind: :list},
    %{file_name: "not-found.liquid", slug: "not-found", title: "Not Found", kind: :not_found}
  ]

  def install(project) do
    source_root = Path.join(Application.app_dir(:bds, "priv/starter_templates"), "templates")
    target_root = Path.join(Projects.project_data_dir(project), "templates")

    :ok = File.mkdir_p(target_root)

    source_root
    |> list_files()
    |> Enum.each(fn source_path ->
      relative_path = Path.relative_to(source_path, source_root)
      target_path = Path.join(target_root, relative_path)
      :ok = File.mkdir_p(Path.dirname(target_path))

      case Enum.find(@top_level_templates, &(&1.file_name == relative_path)) do
        nil ->
          File.cp!(source_path, target_path)

        template ->
          body = File.read!(source_path)

          File.write!(
            target_path,
            Frontmatter.serialize_document(
              [
                {:id, Ecto.UUID.generate()},
                {:slug, template.slug},
                {:title, template.title},
                {:kind, template.kind},
                {:enabled, true},
                {:version, 1}
              ],
              body
            )
          )
      end
    end)

    :ok
  end

  defp list_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.sort()
  end
end
